#!/bin/bash

set -e

echo "🔧 Building papers..."

# Clean output directory
mkdir -p dist

# Find all markdown files under content/
find content -name '*.md' | while read file; do
  rel_path="${file#content/}"
  out_dir="dist/$(dirname "$rel_path")"
  html_filename="$(basename "${file%.md}").html"

  echo "📄 Processing $file → $out_dir/$html_filename"

  mkdir -p "$out_dir"
  npx spec-md "$file" > "$out_dir/$html_filename"

  src_dir="$(dirname "$file")"
  if [ -d "$src_dir/images" ]; then
    echo "🖼️  Copying images from $src_dir/images"
    cp -r "$src_dir/images" "$out_dir/"
  fi
done

echo "✅ Done. Output is in ./dist/"
