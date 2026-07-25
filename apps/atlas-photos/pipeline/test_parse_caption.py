#!/usr/bin/env python3
"""Unit tests for gpu_stages.parse_caption_json — the caption stage's JSON
repair. Stdlib only, no GPU and no model: run it anywhere.

    python3 apps/atlas-photos/pipeline/test_parse_caption.py

Every FAILING_* sample below is real-shaped output that the old
find("{")/rfind("}") slice returned None for, costing a strict retry plus up
to 5 queue attempts — each one reloading the 3.3 GiB vLLM model.
"""
import unittest

from gpu_stages import TAG_SOURCE, TAG_SOURCE_PARTIAL, parse_caption_json

CLEAN = '{"caption": "A boy rides a bike.", "tags": ["boy", "bike", "street"]}'


class ParseCaptionJson(unittest.TestCase):

    def test_clean(self):
        r = parse_caption_json(CLEAN)
        self.assertEqual(r.caption, "A boy rides a bike.")
        self.assertEqual(r.tags, ["boy", "bike", "street"])

    def test_code_fenced(self):
        self.assertIsNotNone(parse_caption_json("```json\n" + CLEAN + "\n```"))

    # --- the three reproduced failure modes -----------------------------

    def test_truncated_keeps_complete_tags(self):
        """max_tokens cut the object mid-array: no closing brace. The tags that
        did make it are still usable; the partial last one is dropped."""
        out = ('{"caption": "A boy rides a bike down a long street.", '
               '"tags": ["boy", "bike", "street", "sum')
        r = parse_caption_json(out)
        self.assertEqual(r.caption, "A boy rides a bike down a long street.")
        self.assertEqual(r.tags, ["boy", "bike", "street"])

    def test_trailing_prose_with_brace(self):
        """rfind used to grab the brace in the prose after the object."""
        out = CLEAN + "\n\nNote: the format {a} was used."
        self.assertEqual(parse_caption_json(out)[1], ["boy", "bike", "street"])

    def test_second_object(self):
        """Model emits a second fenced block; rfind used to span both."""
        out = ("```json\n" + CLEAN + "\n```\n\n```json\n"
               '{"caption": "Another try.", "tags": ["x", "y"]}\n```')
        r = parse_caption_json(out)
        self.assertEqual(r.caption, "A boy rides a bike.")   # FIRST object wins
        self.assertEqual(r.tags, ["boy", "bike", "street"])

    # --- the brace scan must not be fooled by strings -------------------

    def test_brace_inside_caption_string(self):
        out = '{"caption": "A sign reading {open} at night.", "tags": ["sign", "night"]}'
        r = parse_caption_json(out)
        self.assertEqual(r.caption, "A sign reading {open} at night.")
        self.assertEqual(r.tags, ["sign", "night"])

    def test_escaped_quote_in_caption(self):
        out = r'{"caption": "A sign reading \"open\".", "tags": ["sign"]}'
        r = parse_caption_json(out)
        self.assertEqual(r.caption, 'A sign reading "open".')
        self.assertEqual(r.tags, ["sign"])

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


class SalvageIsMarked(unittest.TestCase):
    """A salvaged tag list is a prefix of what the model meant to emit. It must
    be distinguishable from a complete parse *after the fact*, not just in a log
    line — the caption stage maps `partial` onto tags.source so a truncated
    result stays findable for re-tagging."""

    def test_complete_parse_is_not_partial(self):
        self.assertFalse(parse_caption_json(CLEAN).partial)

    def test_complete_parse_is_not_partial_in_every_repaired_shape(self):
        """Fences, trailing prose, a second object, a prose brace ahead of the
        real one — all repaired by the normal decode path, none are salvage."""
        for out in ("```json\n" + CLEAN + "\n```",
                    CLEAN + "\n\nNote: the format {a} was used.",
                    "Here is the {JSON} you asked for:\n" + CLEAN,
                    "```json\n" + CLEAN + "\n```\n\n```json\n"
                    '{"caption": "Another try.", "tags": ["x", "y"]}\n```'):
            self.assertFalse(parse_caption_json(out).partial, out)

    def test_truncated_mid_tag_is_partial(self):
        out = ('{"caption": "A boy rides a bike down a long street.", '
               '"tags": ["boy", "bike", "street", "sum')
        r = parse_caption_json(out)
        self.assertTrue(r.partial)
        self.assertEqual(r.tags, ["boy", "bike", "street"])

    def test_truncated_after_closed_array_is_still_partial(self):
        """Array closed, object did not. Tags happen to be whole, but nothing
        in the text proves that — the model may have had more to say."""
        out = '{"caption": "A boy rides a bike.", "tags": ["boy", "bike"]'
        self.assertTrue(parse_caption_json(out).partial)

    def test_six_of_twelve_tags_is_marked(self):
        """The exact case from the issue: half a tag list, stored as if whole."""
        out = ('{"caption": "A street scene.", "tags": ['
               + ", ".join(f'"t{i}"' for i in range(6)) + ', "t6')
        r = parse_caption_json(out)
        self.assertTrue(r.partial)
        self.assertEqual(len(r.tags), 6)

    def test_sources_differ_and_partial_is_a_prefix_variant(self):
        """Consumers must not equality-test 'qwen2.5-vl'; the partial value is
        a prefix extension so `LIKE 'qwen2.5-vl%'` / IN-lists still catch both."""
        self.assertNotEqual(TAG_SOURCE, TAG_SOURCE_PARTIAL)
        self.assertTrue(TAG_SOURCE_PARTIAL.startswith(TAG_SOURCE))

    def test_result_still_indexes_like_a_tuple(self):
        """[0]/[1] kept working so existing call sites did not silently shift."""
        r = parse_caption_json(CLEAN)
        self.assertEqual(r[0], r.caption)
        self.assertEqual(r[1], r.tags)


if __name__ == "__main__":
    unittest.main(verbosity=2)
