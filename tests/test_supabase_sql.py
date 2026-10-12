"""supabase/setup.sql must survive editors that split statements without understanding comments."""
import re
from pathlib import Path

SETUP = Path(__file__).resolve().parent.parent / "supabase" / "setup.sql"


def split(text: str, comments: bool) -> list[str]:
    out, buf, i, quote, dollar = [], [], 0, False, None
    while i < len(text):
        ch = text[i]
        if dollar:
            if text.startswith(dollar, i):
                buf.append(dollar); i += len(dollar); dollar = None
                continue
        elif quote:
            if ch == "'":
                quote = False
        else:
            if comments and text.startswith("--", i):
                j = text.find("\n", i)
                i = len(text) if j < 0 else j
                continue
            m = re.match(r"\$[A-Za-z_]*\$", text[i:])
            if m:
                dollar = m.group(0); buf.append(dollar); i += len(dollar)
                continue
            if ch == "'":
                quote = True
            elif ch == ";":
                out.append("".join(buf).strip()); buf = []; i += 1
                continue
        buf.append(ch); i += 1
    return out


def test_comments_do_not_change_how_setup_splits():
    text = SETUP.read_text()
    strip = lambda s: re.sub(r"--[^\n]*", "", s).split()
    proper, naive = split(text, True), split(text, False)
    assert [strip(s) for s in proper] == [strip(s) for s in naive]
