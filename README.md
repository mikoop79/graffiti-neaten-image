# Graffiti

Two small command line tools that use OpenAI image editing to transform a picture you give them. You answer a short questionnaire, the script builds a prompt, sends your image to the API, and then lets you keep refining the result until you're happy.

| Script | What it does |
| --- | --- |
| `graffiti.sh` | Turns a scribble or sketch into a graffiti artwork (wildstyle, bubble letters, stencil and so on) painted on a wall, train, roller door or canvas. |
| `neaten.sh` | Cleans up an image: sketches, photos, handwritten notes, whiteboards, logos or scanned documents. Removes smudges, straightens lines, fixes lighting and can give a transparent background. |

Both scripts work the same way, they just ask different questions.

## Requirements

* macOS or Linux (works with the bash 3.2 that ships with macOS)
* `curl`, `jq`, `base64` and `file`
* Optional: ImageMagick (`magick` or `convert`) or macOS `sips`, used to convert formats other than PNG, JPEG and WebP
* An OpenAI API key with access to image models

On macOS, `jq` is the only one you are likely to need to install:

```bash
brew install jq
```

## Setup

1. Copy the example env file and add your key:

   ```bash
   cp env.example .env
   ```

   ```bash
   OPENAI_API_KEY=sk-your-key-here
   OPENAI_IMAGE_MODEL=gpt-image-1   # optional, this is the default
   ```

   The scripts look for `.env` next to the script and in your current folder. You can also just `export OPENAI_API_KEY=...` in your shell.

2. Make the scripts executable:

   ```bash
   chmod +x graffiti.sh neaten.sh
   ```

## Usage

```bash
./graffiti.sh <image>
./neaten.sh <image>
```

`<image>` can be:

* a local file path, e.g. `./sketch.jpg`
* a direct link to an image
* a Google Drive share link (converted to a direct download)
* a Dropbox link (forced to download)
* a share page from Google Photos, Imgur, Flickr and similar sites. The script reads the page's preview image and tries to fetch the full size version. Share a single photo, not an album.

Images must be under 50 MB.

## How a session works

1. **Download and check.** The image is fetched or copied, checked to be a real image, converted if needed, and its size and dimensions are shown.
2. **Questionnaire.** You pick from numbered options or type your own answer. Press Enter to accept the default.
   * `graffiti.sh` asks about what to keep from the sketch, style, influences, line work, colour palette, surface, lighting, extras, a tag signature, aspect ratio, photo or illustration look, and quality.
   * `neaten.sh` asks what kind of image it is, the goal, how closely to follow the original, what to fix, what must stay the same, background, colour, output shape and quality.
3. **Review the prompt.** The full prompt is shown. You can generate, edit it in your `$EDITOR`, or redo the questions.
4. **Generate.** The image is sent to the OpenAI `images/edits` endpoint. Each call takes roughly 30 to 60 seconds and the result opens automatically.
5. **Refine.** After each version you can:
   * finish with the current version
   * tweak the current version by describing a change
   * switch to an earlier version and work from that
   * make a new variation from the original with the same prompt
   * add to the prompt and regenerate from the original
   * redo the questionnaire and regenerate
   * or just type a change directly

## Output

Every run creates its own timestamped folder in the current directory:

```
graffiti_20261022_143005/      (or neaten_...)
  scribble.png                 the input (original.* for neaten.sh)
  v1.png, v2.png, ...          every version generated
  prompts.log                  the exact prompt used for each version
  final.png                    the version you chose when you finished
```

These folders and your `.env` are ignored by git.

## Cost

Every generation, tweak and variation is a paid API call. Higher quality and larger sizes cost more. `graffiti.sh` defaults to medium quality and `neaten.sh` defaults to high. Check OpenAI's current image pricing before long sessions.

## Troubleshooting

| Message | Fix |
| --- | --- |
| `OPENAI_API_KEY not set` | Create `.env` from `env.example` or export the key. |
| `Missing dependency: jq` | Install it, e.g. `brew install jq`. |
| `Download failed. Is the link public?` | Make sure the link works in a private browser window, or download the file and pass the path. |
| `Couldn't find an image on that page` | You probably shared an album. Share one photo, or use a local file. |
| `Can't convert image/...` | Install ImageMagick, or save the image as PNG or JPEG first. |
| `API error (4xx)` | The message from OpenAI is shown. Common causes are an invalid key, no access to the model, or the prompt being rejected by moderation. |
