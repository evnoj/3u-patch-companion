Controls the patch in my 3u rack through crow, primarily controlling params of txo as an enveloped oscillator and w/syn, which are played via ansible.

# crow
## env
- in 2 triggers env coming out of output 3 

# mft mappings
encoders:
- (1,2): txo bass voice (voice 4) waveform shape
  - shift: txo voice 4 level
- (3,2): blooper loop div
  - shift: double/halve
  - switch: set blooper loop based on div
  - intended to be used with blooper as a delay - repeats down, "dub" mode (stay in rec mode when setting loop)
  - led turns off if clock tempo changes to indicate loop time not based on clock
    - divisions: 1/2, 2/3, 3/4, 4/5, 5/6, 1, 6/5, 5/4, 4/3, 3/2, 2
      - 9 o clock is dotted eighth
- (4,2): rmc div
  - shift: double/halve
  - switch: send midi clock taps to set delay time
  - rmc does not support changing time subdivisions when synced to midi clock, so rmc is set to ignore midi clock. To get synced delay, tap tempo signals are sent via midi. this knob sets the division that will be sent, and pressing/releasing the knob's switch sends the midi tap messages
  - led: turns off if the clock tempo changes, to indicate that the rmc's time is no longer based on the clock
    - divisions: 1/2, 2/3, 3/4, 4/5, 5/6, 1, 6/5, 5/4, 4/3, 3/2, 2
      - 9 o clock is dotted eighth

- (1,3): wsyn curve
  - normal value: fully clockwise (5)
  - leds: off is -5, centered is 0, fully lit is 5
  - shift: wsyn ramp
    - normal value: centered (0)
  - switch: reset curve and ramp to 5 and 0 respectively
- (2,3): wsyn fm ratio
  - led: color indicates "zone", indicator is ratio
    - red: non-integer ratios, ccw goes weirder/generally higher
    - amber: integer ratios 1-10
    - violet: integer ratios 11-20
  - shift: exponent of integer divider 2, -5 to 5. 0 is no division, 1 is 2, 2 is 4, etc.
  - switch: reset fm ratio to 4
- (3,3): [crow env](#env) time
  - shift: crow env offset, the "floor" of the output
  - switch: triggers the envelope
  - led indicates level at the output
- (4,3): [crow env](#env) ratio
  - switch: "flips" the ratio around the midpoint, ex. 1/5 (fast attack, slow release) becomes 4/5 (slow attack, fast release). $1-ratio$
  - led indicates level at the output
- (1,4): global clock tempo
  - shift: double/halve global tempo
  - led indicates range it's in:
    - red: 10-40
    - amber: 41-160
    - violet: 161-640
- (2,4): ansible clock division double/halve (txo tr 4)
  - switch: start/stop the clock output
  - indicator light 1-4 correspond directly to division. noon is 8, each successive step doubles
- (3,4): beads clock division double/halve (txo tr 3)
  - switch: start/stop the clock output
  - indicator light 1-4 correspond directly to division. noon is 8, each successive step doubles
- (4,4): beads octave (txo cv 3)
  - shift: move in fifths and octaves instead of just octaves
  - switch: reset to no pitch shift
  - led: color indicates pitch relationship:
    - amber: octave
    - red: fifth (ascending)
    - violet: something else
  - indicator light shows octave, center is no pitch shift

side buttons:
- mirrored on both sides. from top to bottom:
  1. reset ansible (txo tr 3 trigger)
  2. bang params 

# wiring
- crow output 4 to cv in of veils chan, in is wsyn output, changing wsyn fm index (ex. trackball) adjusts VCA down as index increases to maintain perceived volume
  - veils slider at max, offset min, linear response
    - can adjust slider for different responses
- txo tr 3 to ansible reset in
- txo tr 4 to ansible clock in

# todo
- [ ] find good txo waveforms, interpolate between them instead of flat scan through values?
- [ ] more ways of controlling fm ratio
- [ ] test midi mapping
- [ ] improve separation of trackball and params
    - currently the "sensitivity" of the trackball is simply the quantum of the params, should separate this further. Questions: how to make turning param knob lock in to desired steps, even when trackball may set the value to something in between? Maybe an underlying hidden param that is controlled by both?
