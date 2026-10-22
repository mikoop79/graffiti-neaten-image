#!/usr/bin/env bash
# graffiti.sh — turn a scribble into graffiti art with OpenAI image generation.
#
# Usage:
#   ./graffiti.sh <public-image-url | local-file>
#
# Needs: curl, jq, base64 (ImageMagick or macOS sips optional, for format conversion)
# Key:   OPENAI_API_KEY in the environment or in a .env file next to this script / in the cwd:
#          OPENAI_API_KEY=sk-...
#          OPENAI_IMAGE_MODEL=gpt-image-1   # optional
#
# Works with the bash 3.2 that ships on macOS as well as Linux bash.

set -euo pipefail

# ---------- setup ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for envfile in "$SCRIPT_DIR/.env" "./.env"; do
  if [[ -f "$envfile" ]]; then set -a; # shellcheck disable=SC1090
    source "$envfile"; set +a; fi
done

MODEL="${OPENAI_IMAGE_MODEL:-gpt-image-1}"
API="https://api.openai.com/v1/images/edits"

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_ylw=$'\033[33m'; c_off=$'\033[0m'
say()  { printf '%s\n' "$*" >&2; }
info() { say "${c_grn}==>${c_off} $*"; }
warn() { say "${c_ylw}!!${c_off} $*"; }
die()  { say "${c_red}xx${c_off} $*"; exit 1; }

for bin in curl jq base64; do command -v "$bin" >/dev/null || die "Missing dependency: $bin"; done
[[ -n "${OPENAI_API_KEY:-}" ]] || die "OPENAI_API_KEY not set. Put it in .env or export it."
[[ $# -ge 1 ]] || die "Usage: $0 <public-image-url | local-file>"

SRC="$1"
SESSION="graffiti_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SESSION"
LOG="$SESSION/prompts.log"
info "Session folder: $SESSION"

open_file() {
  if command -v open >/dev/null 2>&1; then open "$1"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 &
  else say "Open it yourself: $1"; fi
}

# ask "Question" "default"  -> prints answer (default if blank)
ask() {
  local ans
  read -r -p "${c_bold}$1${c_off} ${c_dim}[$2]${c_off} " ans
  printf '%s' "${ans:-$2}"
}

# choose "Question" opt1 opt2 ...  -> number picks an option, text = custom, blank = option 1
choose() {
  local q="$1"; shift
  local opts=("$@") i ans
  say ""; say "${c_bold}$q${c_off}"
  for ((i=0; i<${#opts[@]}; i++)); do say "  $((i+1))) ${opts[$i]}"; done
  say "  ${c_dim}(enter a number, type your own, or press Enter for 1)${c_off}"
  read -r -p "> " ans
  if [[ -z "$ans" ]]; then printf '%s' "${opts[0]}"
  elif [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then printf '%s' "${opts[$((ans-1))]}"
  else printf '%s' "$ans"; fi
}

# ---------- 1. download ----------------------------------------------------
direct_link() {
  local u="$1" id
  # Google Drive share link -> direct download
  if [[ "$u" =~ drive\.google\.com/file/d/([^/]+) ]]; then
    id="${BASH_REMATCH[1]}"; u="https://drive.google.com/uc?export=download&id=$id"
  elif [[ "$u" =~ drive\.google\.com/open\?id=([^&]+) ]]; then
    id="${BASH_REMATCH[1]}"; u="https://drive.google.com/uc?export=download&id=$id"
  # Dropbox -> force download
  elif [[ "$u" == *dropbox.com* ]]; then
    u="${u//dl=0/dl=1}"; [[ "$u" == *dl=1* || "$u" == *raw=1* ]] || u="$u$([[ "$u" == *\?* ]] && echo '&' || echo '?')dl=1"
  fi
  printf '%s' "$u"
}

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"

# og_image <html_file> -> prints the og:image URL (handles either attribute order)
og_image() {
  tr '\n' ' ' < "$1" \
    | grep -oiE '<meta[^>]+(property|name)="og:image"[^>]*>' | head -n1 \
    | grep -oiE 'content="[^"]+"' | head -n1 | sed -E 's/^content="//; s/"$//; s/&amp;/\&/g'
}

# fetch_image <url> <out> -> tries full-size variants, succeeds only if result is an image
fetch_image() {
  local url="$1" out="$2" base cand
  local cands=()
  if [[ "$url" == *googleusercontent.com* ]]; then
    base="${url%%=*}"                      # strip Google's size suffix (=w600-h315-p-k…)
    cands=("$base=d" "$base=w4096-h4096" "$url")   # =d is the original file
  else
    cands=("$url")
  fi
  for cand in "${cands[@]}"; do
    if curl -fL -sS -A "$UA" -o "$out" "$cand" 2>/dev/null \
       && [[ "$(file --mime-type -b "$out")" == image/* ]]; then
      info "Got full image: $cand"; return 0
    fi
  done
  return 1
}

RAW="$SESSION/original_download"
if [[ -f "$SRC" ]]; then
  info "Using local file: $SRC"
  cp "$SRC" "$RAW"
else
  URL="$(direct_link "$SRC")"
  info "Downloading: $URL"
  curl -fL --retry 2 -sS -A "$UA" -o "$RAW" "$URL" || die "Download failed. Is the link public?"

  # Got a web page (Google Photos / Imgur / Flickr share page) instead of an image?
  # Pull the page's preview image (og:image) and fetch the full-size version.
  if [[ "$(file --mime-type -b "$RAW")" == text/html ]]; then
    info "That's a web page — looking for the photo inside it"
    IMG="$(og_image "$RAW")"
    [[ -n "$IMG" ]] || die "Couldn't find an image on that page. Share a single photo (not an album), or download it and pass the file path."
    fetch_image "$IMG" "$RAW" || die "Found the photo ($IMG) but couldn't download it."
  fi
fi

# ---------- 2. scan --------------------------------------------------------
MIME="$(file --mime-type -b "$RAW" 2>/dev/null || echo unknown)"
BYTES="$(wc -c < "$RAW" | tr -d ' ')"
info "Scan: type=$MIME size=$((BYTES/1024))KB"

[[ "$MIME" == image/* ]] || die "That doesn't look like an image ($MIME). If it's a share link, use the direct/raw image link."
(( BYTES < 50*1024*1024 )) || die "Image is over 50MB — shrink it first."

SCRIBBLE="$SESSION/scribble.png"
case "$MIME" in
  image/png)  cp "$RAW" "$SCRIBBLE" ;;
  image/jpeg) SCRIBBLE="$SESSION/scribble.jpg";  cp "$RAW" "$SCRIBBLE" ;;
  image/webp) SCRIBBLE="$SESSION/scribble.webp"; cp "$RAW" "$SCRIBBLE" ;;
  *)
    info "Converting $MIME to PNG"
    if command -v magick >/dev/null; then magick "$RAW" "$SCRIBBLE"
    elif command -v convert >/dev/null; then convert "$RAW" "$SCRIBBLE"
    elif command -v sips >/dev/null; then sips -s format png "$RAW" --out "$SCRIBBLE" >/dev/null
    else die "Can't convert $MIME — install ImageMagick, or upload a PNG/JPG."; fi ;;
esac
rm -f "$RAW"

if command -v identify >/dev/null; then info "Dimensions: $(identify -format '%wx%h' "$SCRIBBLE" 2>/dev/null)"
elif command -v sips >/dev/null; then info "Dimensions: $(sips -g pixelWidth -g pixelHeight "$SCRIBBLE" | awk '/pixel/{printf "%s ", $2}')"; fi

[[ "$(ask "Open the scribble to check it? (y/n)" "n")" == y* ]] && open_file "$SCRIBBLE"

# ---------- 3. questionnaire -----------------------------------------------
build_prompt() {
  say ""; say "${c_bold}Let's build your prompt.${c_off} Press Enter to accept defaults."

  KEEP=$(ask "Anything specific from the sketch to keep? (e.g. 'the cat's curly tail', 'the word ZAP')" "the main shapes and lines")
  STYLE=$(choose "Graffiti style?" "wildstyle" "bubble letters" "3D block letters" "throw-up" "stencil" "character piece")
  INFLUENCE=$(choose "Influences?" "Melbourne laneway street art" "90s New York subway" "Brazilian pixação" "Japanese pop-graffiti" "European hall-of-fame wall")
  LINES=$(choose "Line work?" "thin white highlight lines" "heavy drop shadows" "chunky 3D extrusion" "all of the above")
  PALETTE=$(choose "Colour palette?" "neon pink, electric blue and acid green" "warm sunset fades (orange, magenta, purple)" "hot pink, teal and sunflower yellow" "monochrome with one bright accent colour" "chrome silver with black outlines")
  SURFACE=$(choose "Painted on?" "weathered brick wall" "concrete underpass" "corrugated roller door" "train carriage" "plain canvas (no setting)")
  LIGHT=$(choose "Lighting?" "bright daylight" "golden hour" "night under a streetlight" "overcast, soft light")
  EXTRAS=$(ask "Extras? (arrows, stars, crown, sparkles… or 'none')" "arrows, stars and sparkles")
  TAG=$(ask "Tag signature text? (leave 'none' for no tag)" "none")
  ASPECT=$(choose "Aspect ratio?" "1:1" "16:9 (landscape)" "9:16 (portrait)")
  RENDER=$(choose "Look?" "photorealistic photo of a real mural" "flat digital illustration")
  QUALITY=$(choose "Quality (higher = slower / pricier)?" "medium" "high" "low")

  case "$ASPECT" in
    16:9*) SIZE="1536x1024" ;;
    9:16*) SIZE="1024x1536" ;;
    *)     SIZE="1024x1024" ;;
  esac
  case "$QUALITY" in low|medium|high) ;; *) QUALITY="medium" ;; esac

  local tagline=""
  [[ "$TAG" != "none" && -n "$TAG" ]] && tagline=" Include a small tag signature reading \"$TAG\"."
  local extrasline=""
  [[ "$EXTRAS" != "none" && -n "$EXTRAS" ]] && extrasline=" Add $EXTRAS."

  PROMPT="Transform the attached scribble into a vibrant, professional graffiti artwork. \
Keep the overall shape, composition and main lines of the scribble, especially: $KEEP. \
Style: $STYLE graffiti, influenced by $INFLUENCE, with bold black outlines and $LINES. \
Colour palette: $PALETTE, with spray-paint effects: soft fades, overspray haze, drips, splatter and a few rough edges. \
Painted on a $SURFACE, lit by $LIGHT.$extrasline$tagline \
Render as a $RENDER. No extra text other than what is specified."
}

review_prompt() {
  while true; do
    say ""; say "${c_bold}Your prompt:${c_off}"; say "$PROMPT"
    say "${c_dim}size=$SIZE quality=$QUALITY model=$MODEL${c_off}"
    local a; a=$(choose "Happy with it?" "go — generate" "edit the text myself" "redo the questions")
    case "$a" in
      go*) return ;;
      edit*)
        local tmp="$SESSION/prompt_edit.txt"; printf '%s\n' "$PROMPT" > "$tmp"
        if [[ -n "${EDITOR:-}" ]]; then "$EDITOR" "$tmp"; PROMPT="$(cat "$tmp")"
        else PROMPT=$(ask "Type the full new prompt" "$PROMPT"); fi ;;
      redo*) build_prompt ;;
      *) PROMPT="$a" ;;   # typed a whole prompt directly
    esac
  done
}

# ---------- 4. generation --------------------------------------------------
VERSIONS=()

mime_of() { case "$1" in *.jpg|*.jpeg) echo image/jpeg;; *.webp) echo image/webp;; *) echo image/png;; esac; }

# generate <input_image> <prompt>  -> appends new version, sets LAST
generate() {
  local input="$1" prompt="$2" n=$(( ${#VERSIONS[@]} + 1 ))
  local out="$SESSION/v$n.png" resp="$SESSION/.resp.json"
  info "Generating v$n from $(basename "$input") … (can take ~30–60s)"
  local code
  code=$(curl -sS -o "$resp" -w '%{http_code}' "$API" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -F "model=$MODEL" \
    -F "image=@$input;type=$(mime_of "$input")" \
    --form-string "prompt=$prompt" \
    -F "size=$SIZE" \
    -F "quality=$QUALITY" \
    -F "n=1") || { warn "Network error."; return 1; }

  if [[ "$code" != 200 ]]; then
    warn "API error ($code): $(jq -r '.error.message // .' "$resp" 2>/dev/null)"
    return 1
  fi

  local b64 url
  b64=$(jq -r '.data[0].b64_json // empty' "$resp")
  url=$(jq -r '.data[0].url // empty' "$resp")
  if [[ -n "$b64" ]]; then printf '%s' "$b64" | base64 --decode > "$out"
  elif [[ -n "$url" ]]; then curl -fsS -o "$out" "$url"
  else warn "No image in response."; return 1; fi
  rm -f "$resp"

  VERSIONS+=("$out")
  LAST="$out"
  printf '=== v%s (from %s) ===\n%s\n\n' "$n" "$(basename "$input")" "$prompt" >> "$LOG"
  info "Saved $out"
  open_file "$out"
}

pick_version() {
  say ""; say "${c_bold}Versions:${c_off}"
  local i
  for ((i=0; i<${#VERSIONS[@]}; i++)); do
    local mark=""; [[ "${VERSIONS[$i]}" == "$BASE" ]] && mark=" ${c_grn}<- current${c_off}"
    say "  $((i+1))) $(basename "${VERSIONS[$i]}")$mark"
  done
  local a; read -r -p "Which one? " a
  if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= ${#VERSIONS[@]} )); then
    BASE="${VERSIONS[$((a-1))]}"; info "Now working from $(basename "$BASE")"
    [[ "$(ask "Open it? (y/n)" "y")" == y* ]] && open_file "$BASE"
  else warn "Not a valid version."; fi
}

# ---------- 5. main loop ---------------------------------------------------
build_prompt
review_prompt

until generate "$SCRIBBLE" "$PROMPT"; do
  [[ "$(ask "Try again? (y/n)" "y")" == y* ]] || exit 1
done
BASE="$LAST"

while true; do
  a=$(choose "What next? (working from $(basename "$BASE"))" \
      "I'm happy — finish with this one" \
      "tweak this version (describe a change)" \
      "pick a different version to work from" \
      "new variation from the original scribble (same prompt)" \
      "redo from scribble with changes added to the prompt" \
      "change the questionnaire answers and regenerate")
  case "$a" in
    "I'm happy"*)
      cp "$BASE" "$SESSION/final.png"
      info "Done! Final image: $SESSION/final.png  (all versions + prompts.log are in $SESSION)"
      open_file "$SESSION/final.png"; exit 0 ;;
    tweak*)
      change=$(ask "What should change?" "make the colours brighter and add more drips")
      generate "$BASE" "Edit this graffiti mural. Keep the same composition, lettering, style and overall colours, but make this change: $change. Keep it looking like real spray paint." && BASE="$LAST" ;;
    pick*) pick_version ;;
    "new variation"*) generate "$SCRIBBLE" "$PROMPT" && BASE="$LAST" ;;
    "redo from scribble"*)
      change=$(ask "What to add to the prompt?" "more texture, grime and spray-can imperfections")
      PROMPT="$PROMPT Also: $change."
      generate "$SCRIBBLE" "$PROMPT" && BASE="$LAST" ;;
    change*) build_prompt; review_prompt; generate "$SCRIBBLE" "$PROMPT" && BASE="$LAST" ;;
    *) generate "$BASE" "Edit this graffiti mural. Keep the same composition and style, but: $a" && BASE="$LAST" ;;
  esac
done
