"""Beat-lattice math: every cue lives on this grid, never on guesses."""
import math

class Lattice:
    def __init__(self, bpm, anchor_ms):
        self.bpm = float(bpm)
        self.anchor = float(anchor_ms)
        self.beat = 60000.0 / self.bpm
        self.eighth = self.beat / 2.0

    def bphase(self, t):                 # ms since the last lattice beat
        return (t - self.anchor) % self.beat

    def beat_idx(self, t):
        return int((t - self.anchor) // self.beat)

    def eighth_idx(self, t):
        return int((t - self.anchor) // self.eighth)

    def env(self, t, decay=250.0):
        return math.exp(-self.bphase(t) / decay)

    def near_dt(self, t):                # distance to the NEAREST beat
        p = self.bphase(t)
        return min(p, self.beat - p)

    def bar(self, t, anchor):            # section-local bar index (bar = 4 beats)
        return int((t - anchor) // (4 * self.beat))

    def grid_ms(self, name):
        return self.eighth if name == "eighth" else self.beat
