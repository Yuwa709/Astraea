import Accelerate
import CoreAudio

/// The IOProc's body: gain, then bass boost and the limiter, then mix, for
/// every stream the aggregate presents. A method rather than a closure so
/// tests can drive it with synthesized buffers; no test ever runs it on a
/// device.
///
/// The per-sample work is vDSP whenever possible: the app ships and runs as
/// a Debug build, where a per-frame Swift loop costs ~50x its Release self
/// (measured 2026-09-19: 3.2 s/60 s of one core for a single leg, against a
/// 0.19 s Release reference). vDSP is a library call and pays no such tax.
/// Realtime-safe: no allocation, no locks, no ObjC — everything touched
/// here was allocated in `init`.
extension TapRenderState {

    nonisolated func render(inputs: UnsafeMutableAudioBufferListPointer,
                            outputs: UnsafeMutableAudioBufferListPointer) {
        // Before anything can return: the engine waits on this word to know
        // a tap-list edit has landed.
        observedBufferCount.pointee = Int32(truncatingIfNeeded: inputs.count)
        guard let out = outputs.first, let outRaw = out.mData else { return }
        let outSamples = Int(out.mDataByteSize) / MemoryLayout<Float>.size
        let outPtr = outRaw.assumingMemoryBound(to: Float.self)
        vDSP_vclr(outPtr, 1, vDSP_Length(outSamples))

        let bufferCount = min(inputs.count, Self.maxLegs)
        let row = bufferCount * Self.maxLegs
        // Whether any leg can leave full scale this callback, which is the
        // only time the bus limiter runs (besides finishing a release).
        var anyAboveUnity = false
        for (stream, buffer) in inputs.enumerated() where stream < bufferCount {
            guard let raw = buffer.mData else { continue }
            let samples = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, outSamples)
            guard samples > 0 else { continue }
            let inPtr = UnsafePointer(raw.assumingMemoryBound(to: Float.self))
            let slot = Int(mapping[row + stream])
            if slot < 0 || slot >= Self.maxLegs {
                // Unmapped stream: pass through at unity, unfiltered. Safe
                // for the one-callback window around a topology edit.
                vDSP_vadd(outPtr, 1, inPtr, 1, outPtr, 1, vDSP_Length(samples))
                continue
            }
            let channels = Int(max(1, buffer.mNumberChannels))
            // The slot changed hands since this thread last filtered it:
            // its history is the previous leg's and must not ring on.
            let generation = generations[slot]
            if generation != seenGenerations[slot] {
                seenGenerations[slot] = generation
                resetFilter(slot)
            }
            // Above the app's own volume the gain itself can leave full
            // scale, so the leg runs through the limiter even with no bass
            // boost. Until the ramp is back at unity, not just the target,
            // so the limiter lets go only once nothing above unity remains.
            let bass = Int(bassLevels[slot])
            let louder = targets[slot] > 1 || current[slot] > 1
            if louder { anyAboveUnity = true }
            let level = bass == 0 && louder ? Self.flatLevel : bass
            let applied = Int(appliedLevels[slot])
            if (level == 0 && applied == 0) || channels > Self.channelsFiltered {
                // No boost, at or below unity — the common case, and
                // exactly the Phase 5 path.
                mix(inPtr, into: outPtr, samples: samples, slot: slot, channels: channels)
                continue
            }
            boostAndMix(inPtr, into: outPtr, samples: samples, slot: slot,
                        channels: channels, level: level, applied: applied)
        }
        // Each leg above unity is limited on its own, but two of them (or
        // one plus an unmapped stream) can still sum past full scale. At or
        // below unity nothing here runs, so that path stays bit-identical.
        if anyAboveUnity || busGain.pointee < 1 {
            limitBus(outPtr, samples: outSamples)
        }
    }

    /// The output bus's brick wall at full scale: a block gain per callback
    /// from the bus peak, with the per-leg limiter's hold and release. No
    /// lookahead (it would delay every leg), so an attack reaches its gain
    /// over the first `busAttackFrames` and a clip at full scale catches
    /// what those frames let past. A single leg never reaches it: each is
    /// already held at −1 dBFS by its own limiter.
    private nonisolated func limitBus(_ output: UnsafeMutablePointer<Float>, samples: Int) {
        guard samples > 0 else { return }
        let n = vDSP_Length(samples)
        var peak: Float = 0
        vDSP_maxmgv(output, 1, &peak, n)
        let allowed: Float = peak > 1 ? 1 / peak : 1
        let gain = busGain.pointee
        var hold = Int(busHold.pointee)
        // Frames, assuming the interleaved stereo the device gate requires;
        // only the hold and release timing depend on it.
        let frames = max(samples / Self.channelsFiltered, 1)
        var next: Float
        if allowed < gain {
            next = allowed
            hold = busHoldFrames
        } else if hold > 0 {
            next = gain
            hold = max(hold - frames, 0)
        } else {
            next = min(allowed, 1 - (1 - gain) * exp(-Float(frames) / busReleaseFrames))
            // Recovered to within 0.001 dB: done, and the stage goes idle.
            if next > 0.9999 && allowed >= 1 { next = 1 }
        }
        if next < gain {
            let ramp = min(Self.busAttackFrames * Self.channelsFiltered, samples)
            var start = gain
            var step = (next - gain) / Float(ramp)
            vDSP_vrampmul(output, 1, &start, &step, output, 1, vDSP_Length(ramp))
            if samples > ramp {
                vDSP_vsmul(output + ramp, 1, &next, output + ramp, 1, vDSP_Length(samples - ramp))
            }
        } else if next > gain {
            var start = gain
            var step = (next - gain) / Float(samples)
            vDSP_vrampmul(output, 1, &start, &step, output, 1, n)
        } else if gain < 1 {
            vDSP_vsmul(output, 1, &next, output, 1, n)
        }
        if peak * max(gain, next) > 1 {
            var low: Float = -1
            var high: Float = 1
            vDSP_vclip(output, 1, &low, &high, output, 1, n)
        }
        busGain.pointee = next
        busHold.pointee = Int32(hold)
    }

    /// How fast the bus limiter reaches an attack's gain: ~0.7 ms at 48 kHz.
    nonisolated static let busAttackFrames = 32

    private nonisolated func resetFilter(_ slot: Int) {
        appliedLevels[slot] = 0
        let count = Self.channelsFiltered * Self.delayPerChannel
        vDSP_vclr(delays + slot * count, 1, vDSP_Length(count))
        resetLimiter(slot)
    }

    private nonisolated func resetLimiter(_ slot: Int) {
        limiterGains[slot] = 1
        limiterHolds[slot] = 0
        let lane = Self.channelsFiltered * Self.maxLookahead
        vDSP_vclr(limiterDelays + slot * lane, 1, vDSP_Length(lane))
    }

    /// The boosted path, a chunk at a time so any buffer size fits the
    /// preallocated scratch: gain, then shelf, then limiter, then mix. The
    /// gain comes first so the limiter sees what will actually play — above
    /// unity it is the gain that clips, and the shelf is linear, so the
    /// order makes no difference to the curve. A level change crossfades
    /// over this one callback from the old curve (or dry, for off) to the
    /// new one, both run over the same input, so the switch never clicks.
    /// `BassBoost` treats `flatLevel` as no shelf, so above unity with no
    /// bass boost this is gain and limiter alone.
    ///
    /// The limiter delays the boosted audio by its lookahead, so switching
    /// on and off crossfades between the dry signal and a copy 1 ms behind
    /// it. Switching on, the limiter's delay line starts silent; the fade
    /// waits out that silence before it begins, or it would dip.
    private nonisolated func boostAndMix(_ input: UnsafePointer<Float>,
                                         into output: UnsafeMutablePointer<Float>,
                                         samples: Int, slot: Int, channels: Int,
                                         level: Int, applied: Int) {
        let historyCount = Self.channelsFiltered * Self.delayPerChannel
        let history = delays + slot * historyCount
        let whole = (samples / channels) * channels
        guard whole > 0 else { return }
        let fading = level != applied
        if fading && applied == 0 {
            // Off to on: any history here is from an earlier on-period of
            // this leg, not from the audio arriving now.
            vDSP_vclr(history, 1, vDSP_Length(historyCount))
            resetLimiter(slot)
        } else if fading && applied == Self.flatLevel {
            // Flat ran no shelf, so the history is from before it: stale.
            vDSP_vclr(history, 1, vDSP_Length(historyCount))
        }
        if fading && applied != 0 && level != 0 {
            // Level to level: the outgoing curve runs on a copy, and the
            // incoming one inherits the real history — close enough to its
            // own steady state for the crossfade to hide the difference.
            crossfadeDelay.update(from: history, count: historyCount)
        }
        let outgoing = scratch
        let incoming = scratch + Self.chunkSamples
        let mixed = scratch + 2 * Self.chunkSamples
        let scaled = scratch + 3 * Self.chunkSamples
        // Off to on: dry until the limiter's delay line has filled with
        // boosted audio. Half the buffer at most, for a buffer shorter than
        // two lookaheads.
        let wait = fading && applied == 0 ? min(limiterLookahead * channels, whole / 2) : 0
        var fade = Crossfade(fadeIn: 0, fadeOut: 1, step: 1 / Float(max(whole - wait - 1, 1)), wait: wait)

        var offset = 0
        while offset < whole {
            let count = min(Self.chunkSamples, whole - offset)
            let destination = output + offset
            // The gain ramp, into silence: `mix` accumulates.
            vDSP_vclr(scaled, 1, vDSP_Length(count))
            mix(input + offset, into: scaled, samples: count, slot: slot, channels: channels)
            let source = UnsafePointer(scaled)
            guard fading else {
                biquad(level, history: history, source, into: incoming, count: count, channels: channels)
                limit(incoming, count: count, slot: slot, channels: channels)
                accumulate(incoming, into: destination, count: count)
                offset += count
                continue
            }
            if applied != 0 && level != 0 {
                // Both curves through one limiter: its delay stays continuous.
                biquad(applied, history: crossfadeDelay, source, into: outgoing, count: count, channels: channels)
                biquad(level, history: history, source, into: incoming, count: count, channels: channels)
                fade.run(new: incoming, old: outgoing, into: mixed, count: count, at: offset)
                limit(mixed, count: count, slot: slot, channels: channels)
            } else if level != 0 {
                biquad(level, history: history, source, into: incoming, count: count, channels: channels)
                limit(incoming, count: count, slot: slot, channels: channels)
                fade.run(new: incoming, old: source, into: mixed, count: count, at: offset)
            } else {
                biquad(applied, history: history, source, into: outgoing, count: count, channels: channels)
                limit(outgoing, count: count, slot: slot, channels: channels)
                fade.run(new: source, old: outgoing, into: mixed, count: count, at: offset)
            }
            accumulate(mixed, into: destination, count: count)
            offset += count
        }
        appliedLevels[slot] = Int32(level)
    }

    /// The limiter (`BassBoost.Limiter`), in place over one chunk: the
    /// chunk comes out `limiterLookahead` frames late, times a gain that
    /// ramps linearly between knots one block apart. Each knot is the
    /// gain the knee allows for the loudest sample, either channel, in the
    /// block before it and the block after it — which the lookahead lets
    /// it see — so no sample passes the ceiling. Per block, not per sample:
    /// a peak scan and a ramp per channel, all vDSP, so the Debug build's
    /// per-sample tax never applies.
    private nonisolated func limit(_ buffer: UnsafeMutablePointer<Float>,
                                   count: Int, slot: Int, channels: Int) {
        let frames = count / channels
        guard frames > 0 else { return }
        let block = limiterLookahead
        let delayed = block * channels
        let line = limiterDelays + slot * Self.channelsFiltered * Self.maxLookahead
        let work = limiterScratch
        work.update(from: line, count: delayed)
        (work + delayed).update(from: buffer, count: frames * channels)

        var gain = limiterGains[slot]
        var hold = Int(limiterHolds[slot])
        var frame = 0
        while frame < frames {
            let length = min(block, frames - frame)
            var peak: Float = 0
            vDSP_maxmgv(work + frame * channels, 1, &peak, vDSP_Length((length + block) * channels))
            let allowed = BassBoost.Limiter.gain(forPeak: peak)
            let next: Float
            if allowed <= gain * BassBoost.Limiter.holdMargin {
                // At or past the current reduction: attack, or settle the
                // last 0.1 dB up onto exactly what this peak needs — held
                // below it, the gain would sit up to 0.1 dB too low for as
                // long as the note lasts. Either way, re-arm the hold.
                next = allowed
                hold = limiterHoldFrames
            } else if hold > 0 {
                next = gain
                hold = max(hold - length, 0)
            } else {
                // A whole block, nearly always: its release step is cached.
                let decay = length == block ? limiterReleaseStep
                                            : exp(-Float(length) / limiterReleaseFrames)
                let recovered = 1 - (1 - gain) * decay
                next = min(allowed, recovered)
            }
            var step = (next - gain) / Float(length)
            for channel in 0..<channels {
                var start = gain
                vDSP_vrampmul(work + frame * channels + channel, channels, &start, &step,
                              buffer + frame * channels + channel, channels, vDSP_Length(length))
            }
            gain = next
            frame += length
        }
        line.update(from: work + frames * channels, count: delayed)
        limiterGains[slot] = gain
        limiterHolds[slot] = Int32(hold)
    }

    /// One section per channel over interleaved samples, each channel with
    /// its own history: left's bass never leaks into right's filter.
    private nonisolated func biquad(_ level: Int, history: UnsafeMutablePointer<Float>,
                                    _ source: UnsafePointer<Float>,
                                    into destination: UnsafeMutablePointer<Float>,
                                    count: Int, channels: Int) {
        guard BassBoost.levels.contains(level), let setup = setups[level] else {
            destination.update(from: source, count: count)
            return
        }
        let frames = vDSP_Length(count / channels)
        for channel in 0..<channels {
            vDSP_biquad(setup, history + channel * Self.delayPerChannel,
                        source + channel, channels,
                        destination + channel, channels, frames)
        }
    }

    /// Mix at unity: the boosted path has already applied the gain.
    private nonisolated func accumulate(_ input: UnsafePointer<Float>,
                                        into output: UnsafeMutablePointer<Float>, count: Int) {
        vDSP_vadd(input, 1, output, 1, output, 1, vDSP_Length(count))
    }

    /// Gain and accumulate: the Phase 5 path.
    private nonisolated func mix(_ input: UnsafePointer<Float>,
                                 into output: UnsafeMutablePointer<Float>,
                                 samples: Int, slot: Int, channels: Int) {
        var gain = current[slot]
        var target = targets[slot]
        // A leg handing over to its replacement in this aggregate holds its
        // level until the replacement's stream has arrived (a rebuild's
        // crossfade; see `handoverSlots`).
        let replacement = Int(handoverSlots[slot])
        if replacement >= 0, replacement < Self.maxLegs,
           seenGenerations[replacement] != handoverGenerations[slot] {
            target = gain
        }
        if gain == target {
            // Steady state — the overwhelmingly common case: one scaled
            // accumulate over the whole buffer.
            if gain != 0 {
                vDSP_vsma(input, 1, &gain, output, 1, output, 1, vDSP_Length(samples))
            }
            return
        }
        // Ramping: a couple of buffers per gain change, but every buffer
        // of a slider drag. The same ramp the scalar per-frame loop made —
        // each frame steps the gain by `slewPerFrame` toward the target,
        // then lands on it once within one step — as vDSP: a ramp over the
        // frames still more than a step away, then the target over the
        // rest. Whole frames only, as before.
        let frames = samples / channels
        guard frames > 0 else { return }
        let distance = abs(target - gain)
        let step = target > gain ? slewPerFrame : -slewPerFrame
        // Frame j plays gain + (j + 1)·step while the gain it starts from is
        // more than a step from the target, i.e. for j < distance/slew − 1.
        let stepsAway = (distance / slewPerFrame).rounded(.up) - 1
        let ramped = stepsAway > 0 ? min(frames, Int(stepsAway)) : 0
        if ramped > 0 {
            var increment = step
            for c in 0..<channels {
                var start = gain + step
                vDSP_vrampmuladd(input + c, channels, &start, &increment,
                                 output + c, channels, vDSP_Length(ramped))
            }
        }
        if ramped < frames {
            if target != 0 {
                vDSP_vsma(input + ramped * channels, 1, &target,
                          output + ramped * channels, 1,
                          output + ramped * channels, 1,
                          vDSP_Length((frames - ramped) * channels))
            }
            current[slot] = target
        } else {
            current[slot] = gain + step * Float(ramped)
        }
    }
}

/// One callback's crossfade, carried across chunks: `new` ramps in and
/// `old` out, per sample, after `wait` samples of `old` alone.
private struct Crossfade {
    var fadeIn: Float
    var fadeOut: Float
    var step: Float
    let wait: Int

    nonisolated mutating func run(new: UnsafePointer<Float>, old: UnsafePointer<Float>,
                                  into mixed: UnsafeMutablePointer<Float>, count: Int, at offset: Int) {
        let held = min(max(wait - offset, 0), count)
        if held > 0 { mixed.update(from: old, count: held) }
        let ramped = count - held
        guard ramped > 0 else { return }
        var negativeStep = -step
        vDSP_vrampmul(new + held, 1, &fadeIn, &step, mixed + held, 1, vDSP_Length(ramped))
        vDSP_vrampmuladd(old + held, 1, &fadeOut, &negativeStep, mixed + held, 1, vDSP_Length(ramped))
    }
}
