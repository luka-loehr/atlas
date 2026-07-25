#!/usr/bin/env python3
"""Unit tests for gpu_stages.parse_caption_json — the caption stage's JSON
repair. Stdlib only, no GPU and no model: run it anywhere.

    python3 apps/atlas-photos/pipeline/test_parse_caption.py

Every FAILING_* sample below is real-shaped output that the old
find("{")/rfind("}") slice returned None for, costing a strict retry plus up
to 5 queue attempts — each one reloading the 3.3 GiB vLLM model.
"""
import unittest

from gpu_stages import parse_caption_json

CLEAN = '{"caption": "A boy rides a bike.", "tags": ["boy", "bike", "street"]}'


class ParseCaptionJson(unittest.TestCase):

    def test_clean(self):
        caption, tags = parse_caption_json(CLEAN)
        self.assertEqual(caption, "A boy rides a bike.")
        self.assertEqual(tags, ["boy", "bike", "street"])

    def test_code_fenced(self):
        self.assertIsNotNone(parse_caption_json("```json\n" + CLEAN + "\n```"))

    # --- the three reproduced failure modes -----------------------------

    def test_truncated_keeps_complete_tags(self):
        """max_tokens cut the object mid-array: no closing brace. The tags that
        did make it are still usable; the partial last one is dropped."""
        out = ('{"caption": "A boy rides a bike down a long street.", '
               '"tags": ["boy", "bike", "street", "sum')
        caption, tags = parse_caption_json(out)
        self.assertEqual(caption, "A boy rides a bike down a long street.")
        self.assertEqual(tags, ["boy", "bike", "street"])

    def test_trailing_prose_with_brace(self):
        """rfind used to grab the brace in the prose after the object."""
        out = CLEAN + "\n\nNote: the format {a} was used."
        self.assertEqual(parse_caption_json(out)[1], ["boy", "bike", "street"])

    def test_second_object(self):
        """Model emits a second fenced block; rfind used to span both."""
        out = ("```json\n" + CLEAN + "\n```\n\n```json\n"
               '{"caption": "Another try.", "tags": ["x", "y"]}\n```')
        caption, tags = parse_caption_json(out)
        self.assertEqual(caption, "A boy rides a bike.")   # FIRST object wins
        self.assertEqual(tags, ["boy", "bike", "street"])

    # --- the brace scan must not be fooled by strings -------------------

    def test_brace_inside_caption_string(self):
        out = '{"caption": "A sign reading {open} at night.", "tags": ["sign", "night"]}'
        caption, tags = parse_caption_json(out)
        self.assertEqual(caption, "A sign reading {open} at night.")
        self.assertEqual(tags, ["sign", "night"])

    def test_escaped_quote_in_caption(self):
        out = r'{"caption": "A sign reading \"open\".", "tags": ["sign"]}'
        caption, tags = parse_caption_json(out)
        self.assertEqual(caption, 'A sign reading "open".')
        self.assertEqual(tags, ["sign"])

    def test_prose_brace_before_object(self):
        """A "{...}" aside ahead of the real object must be skipped, not taken."""
        out = 'Here is the {JSON} you asked for:\n' + CLEAN
        self.assertEqual(parse_caption_json(out)[1], ["boy", "bike", "street"])

    def test_truncated_mid_caption_is_unparseable(self):
        """Nothing usable yet — no complete caption, no tags. Still None."""
        self.assertIsNone(parse_caption_json('{"caption": "A boy rides a bi'))

    # --- guards that must survive the rewrite ---------------------------

    def test_example_echo_rejected(self):
        out = ('{"caption": "A dog runs.", '
               '"tags": ["dog", "beach", "waves", "running", "summer"]}')
        self.assertIsNone(parse_caption_json(out))

    def test_instruction_echo_tags_dropped(self):
        out = ('{"caption": "A boy rides a bike.", '
               '"tags": ["keyword", "lowercase english", "bike", "...", "bike"]}')
        self.assertEqual(parse_caption_json(out)[1], ["bike"])

    def test_no_caption_rejected(self):
        self.assertIsNone(parse_caption_json('{"tags": ["boy", "bike"]}'))

    def test_no_tags_rejected(self):
        self.assertIsNone(parse_caption_json('{"caption": "A boy.", "tags": []}'))

    def test_garbage_rejected(self):
        for out in ("", "I cannot describe this image.", "{{{", "[1, 2, 3]"):
            self.assertIsNone(parse_caption_json(out), out)

    def test_tags_capped_at_12(self):
        tags = [f"t{i}" for i in range(20)]
        out = '{"caption": "x.", "tags": [%s]}' % ", ".join(f'"{t}"' for t in tags)
        self.assertEqual(parse_caption_json(out)[1], tags[:12])


if __name__ == "__main__":
    unittest.main(verbosity=2)
