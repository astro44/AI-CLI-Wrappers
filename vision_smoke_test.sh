#!/usr/bin/env bash
# vision_smoke_test.sh — empirically proves which CLI wrappers actually deliver
# image vision to their model. Generates one magenta reference image containing a
# distinctive text token, invokes each wrapper through its uniform --image path,
# and scores the response:
#   PASS    = model transcribed the embedded token  (true pixel/OCR vision)
#   PARTIAL = model named the magenta color only     (sees color, token unproven)
#   FAIL    = neither / declared NO-VISION            (blind)
#   ERROR   = wrapper exited non-zero (quota/timeout) -> vision inconclusive
#
# Usage:
#   ./vision_smoke_test.sh                 # all providers
#   VISION_TEST_PROVIDERS="codex agravity" ./vision_smoke_test.sh
#   VISION_TEST_TIMEOUT=90 ./vision_smoke_test.sh
set -uo pipefail

WRAPPER_DIR="${WRAPPER_DIR:-/Users/astrix/repos/AI-CLI-Wrappers}"
OUTDIR="${OUTDIR:-/tmp/vision_smoke_$$}"
TIMEOUT="${VISION_TEST_TIMEOUT:-90}"
TOKEN="${VISION_TEST_TOKEN:-VISION-OK-7Q9Z}"
read -r -a PROVIDERS <<< "${VISION_TEST_PROVIDERS:-claude codex cursor opencode gemini agravity}"

REF="$OUTDIR/vision_ref.png"
mkdir -p "$OUTDIR"

# ---------------------------------------------------------------------------
# 1. Generate the reference image: pure magenta (#FF00FF) bg, large black token.
# ---------------------------------------------------------------------------
python3 - "$REF" "$TOKEN" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
path, token = sys.argv[1], sys.argv[2]
W, H = 1000, 340
img = Image.new("RGB", (W, H), (255, 0, 255))  # pure magenta #FF00FF
d = ImageDraw.Draw(img)
font = None
for p in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf",
          "/System/Library/Fonts/Supplemental/Arial.ttf",
          "/Library/Fonts/Arial.ttf",
          "/System/Library/Fonts/Helvetica.ttc"):
    try:
        font = ImageFont.truetype(p, 96); break
    except Exception:
        continue
if font is None:
    font = ImageFont.load_default()
try:
    bbox = d.textbbox((0, 0), token, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
except Exception:
    tw, th = len(token) * 52, 96
d.text(((W - tw) / 2, (H - th) / 2 - bbox[1] if 'bbox' in dir() else (H - th) / 2),
       token, fill=(0, 0, 0), font=font)
img.save(path)
print("reference image:", path, img.size)
PY
[[ -f "$REF" ]] || { echo "FATAL: could not generate reference image"; exit 1; }

PROMPT="Look at the attached image. Reply in EXACTLY two lines and nothing else. Line 1: COLOR=<the single dominant background color, common name or hex>. Line 2: TEXT=<transcribe the text visible in the image exactly, character for character>. If you cannot actually see the image pixels, reply with only: NO-VISION"

# ---------------------------------------------------------------------------
# 2. Run each wrapper sequentially (limits contention with any live sprint).
#    Isolated CWD so wrapper session/context files do not touch a real project.
# ---------------------------------------------------------------------------
echo
echo "Vision smoke test — token=$TOKEN  timeout=${TIMEOUT}s  providers=${PROVIDERS[*]}"
echo "------------------------------------------------------------------------------"
printf '%-10s %-7s %-7s %-9s %s\n' PROVIDER COLOR TOKEN VERDICT NOTE
printf '%-10s %-7s %-7s %-9s %s\n' "--------" "-----" "-----" "-------" "----"

for p in "${PROVIDERS[@]}"; do
  wrapper="$WRAPPER_DIR/$p.sh"
  raw="$OUTDIR/$p.out"; errf="$OUTDIR/$p.err"
  if [[ ! -x "$wrapper" ]]; then
    printf '%-10s %-7s %-7s %-9s %s\n' "$p" "-" "-" "MISSING" "$wrapper not executable"
    continue
  fi
  # Per-provider invocation quirks:
  #  - codex: parse_arg_json_or_stdin prefers stdin when stdin is not a TTY
  #    (which it isn't when backgrounded), so deliver the prompt via stdin.
  #  - gemini: refuses to run in an untrusted folder; trust the workspace.
  (
    cd "$OUTDIR" || exit 97
    case "$p" in
      codex)
        printf '%s' "$PROMPT" | "$wrapper" --image "$REF" --allow-tools --yolo --timeout "$TIMEOUT" ;;
      gemini)
        GEMINI_CLI_TRUST_WORKSPACE=true "$wrapper" --image "$REF" --allow-tools --yolo --timeout "$TIMEOUT" "$PROMPT" ;;
      *)
        "$wrapper" --image "$REF" --allow-tools --yolo --timeout "$TIMEOUT" "$PROMPT" ;;
    esac
  ) >"$raw" 2>"$errf" &
  pid=$!
  ( sleep $((TIMEOUT + 45)); kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) &
  wd=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$wd" 2>/dev/null

  resp="$(jq -r '.response // empty' "$raw" 2>/dev/null)"
  [[ -z "$resp" ]] && resp="$(cat "$raw" 2>/dev/null)"
  low="$(printf '%s' "$resp" | tr 'A-Z' 'a-z')"

  color=NO; token=NO
  printf '%s' "$low"  | grep -qE 'magenta|ff00ff|fuchsia|bright pink|hot pink' && color=YES
  printf '%s' "$resp" | grep -qF "$TOKEN" && token=YES

  if   [[ "$token" == YES ]]; then verdict=PASS
  elif [[ "$color" == YES ]]; then verdict=PARTIAL
  elif [[ $rc -ne 0 || -z "$resp" ]]; then verdict=ERROR
  else verdict=FAIL; fi

  note=""
  printf '%s' "$low" | grep -q 'no-vision' && note="declared NO-VISION"
  [[ $rc -ne 0 ]] && note="${note:+$note; }rc=$rc"
  [[ -z "$resp" ]] && note="${note:+$note; }empty response"

  printf '%-10s %-7s %-7s %-9s %s\n' "$p" "$color" "$token" "$verdict" "$note"
done

echo "------------------------------------------------------------------------------"
echo "raw responses + stderr saved under: $OUTDIR"
echo "Legend: PASS=read token (true vision)  PARTIAL=color only  FAIL=blind  ERROR=call failed"
