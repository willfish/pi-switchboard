"""Syntax/reference fixtures; compiler execution is tooling, never source execution."""
import importlib.util
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("references", ROOT / "scripts/check-package-references.py")
references = importlib.util.module_from_spec(spec)
spec.loader.exec_module(references)
TYPESCRIPT = os.environ.get("PI_PACKAGE_TYPESCRIPT", str(ROOT / "node_modules/typescript/lib/typescript.js"))


class References(unittest.TestCase):
    def setUp(self):
        self.files = {"index.ts": b'export type { X } from "./extension/x.ts";',
                      "extension/x.ts": b'export type X = string;',
                      "README.md": b'[Guide](docs/a.md)', "docs/a.md": b'# A'}

    def check_ts(self, source):
        references.check({**self.files, "index.ts": source.encode()}, TYPESCRIPT)

    def test_static_import_forms_and_comments(self):
        for source in [
            'import /* comment */ "./extension/x.ts";',
            'import type {\n X\n} from /* comment */ "./extension/x.ts";',
            'export /* comment */ type {X} from "./extension/x.ts";',
            'type T = import(/* comment */ "./extension/x.ts").X;',
            'void import(/* comment */ "./extension/x.ts");',
            'const x = require(/* comment */ "./extension/x.ts");',
            'import x = require("./extension/x.ts");',
            'void import(`./extension/x.ts`);',
            'import "\\u002e/extension/x.ts";',
        ]:
            with self.subTest(source=source):
                self.check_ts(source)
                with self.assertRaises(ValueError):
                    self.check_ts(source.replace('extension/x', 'missing'))

    def test_computed_loading_and_bad_syntax_fail_closed(self):
        for source in [
            'const p = "./extension/x.ts"; void import(p);',
            'require("./" + "extension/x.ts");',
            '(0, require)("./extension/x.ts");',
            'const load = require; load("./extension/x.ts");',
            'require.call(null, "./extension/x.ts");',
            'import * as m from "node:module"; m.createRequire(import.meta.url)("./extension/x.ts");',
            'import {createRequire as r} from "node:module";',
            'eval("import(\\"./extension/x.ts\\")");',
            'import {',
            'import "../outside.ts";',
            'import "https://example.invalid/code.js";',
        ]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                self.check_ts(source)

    def test_transparent_require_wrappers_do_not_hide_targets(self):
        for call in ['(require)', '(require as any)', '(require!)', '(require satisfies any)', '(require).resolve']:
            with self.subTest(call=call):
                self.check_ts(f'{call}("./extension/x.ts");')
                with self.assertRaises(ValueError):
                    self.check_ts(f'{call}("./missing.ts");')
                with self.assertRaises(ValueError):
                    self.check_ts(f'const target = "./extension/x.ts"; {call}(target);')

    def test_source_examples_are_not_executed_or_treated_as_imports(self):
        self.check_ts('const example = "import \'./missing.ts\'"; /* import "./also-missing.ts" */')

    def check_md(self, text):
        references.check_markdown({**self.files, "README.md": text.encode()})

    def test_inline_image_fragment_external_and_encoded_paths(self):
        self.check_md('[x](docs/a.md) ![x](<docs/a.md>) [self](#a) [url](https://example.invalid/a)')
        self.check_md('[x](docs/%61.md)')
        for text in ['[x](missing.md)', '[x](../outside.md)', '[x](%2e%2e/outside.md)',
                     '[x](docs/%ZZ.md)', '[x](javascript:bad)', '[x](docs/a.md?x=1)']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.check_md(text)

    def test_full_collapsed_shortcut_references_and_unused_definitions(self):
        self.check_md('[Title][ref name]\n[Ref Name][]\n[REF NAME]\n\n[Ref Name]: docs/a.md\n')
        self.check_md('[unused]: docs/a.md\n')
        for text in ['[Title][ref]\n[ref]: missing.md', '[unused]: missing.md', '[Title][undefined]',
                     '[ref]:\n missing.md', '[two\nwords]: missing.md', '[ref]: docs/a.md "unsupported title"']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.check_md(text)

    def test_nested_images_and_code_like_destinations_are_not_skipped(self):
        for text in ['[![image](missing.md)](docs/a.md)', '[![image](missing.md)]', '[x](`missing.md`)',
                     '[ref]: `hidden/`docs/a.md\n[x][ref]']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.check_md(text)

    def test_code_and_comments_do_not_create_links(self):
        self.check_md('```md\n[x](missing.md)\n[ref]: absent.md\n```\n'
                      '`[x](missing.md)`\n``code ``` [x](missing.md)``\n'
                      '<!-- [x](missing.md) -->\n[x](docs/a.md)')

    def test_unsupported_markdown_is_rejected_not_ignored(self):
        for text in ['<a href="missing.md">x</a>', '<IMG src="missing.md">',
                     '[x](docs/a\\(b\\).md)', '    [x](missing.md)',
                     '```\nunclosed', '`unclosed [x](missing.md)']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.check_md(text)

    def test_current_approved_package_references(self):
        import json
        inventory = json.loads((ROOT / "tests/fixtures/npm-package-files.json").read_text())
        references.check({name: (ROOT / name).read_bytes() for name in inventory}, TYPESCRIPT)


if __name__ == '__main__':
    unittest.main()
