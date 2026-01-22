#!/bin/bash
#
# Split a merged genome file into equal-sized chunks for parallel processing.
#
# Usage:
#   ./split_merged_file.sh merged_genomes.txt 1024 output_dir
#
# Arguments:
#   $1 - Input merged file
#   $2 - Number of output chunks (e.g., 1024)
#   $3 - Output directory (optional, defaults to 'split_data')
#

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <merged_file> <num_chunks> [output_dir]"
    echo ""
    echo "Example: $0 merged_genomes.txt 1024 split_data"
    exit 1
fi

MERGED_FILE="$1"
NUM_CHUNKS="$2"
OUTPUT_DIR="${3:-split_data}"

# Verify input file exists
if [ ! -f "$MERGED_FILE" ]; then
    echo "Error: Input file $MERGED_FILE not found"
    exit 1
fi

# Verify num_chunks is a positive integer
if ! [[ "$NUM_CHUNKS" =~ ^[0-9]+$ ]] || [ "$NUM_CHUNKS" -lt 1 ]; then
    echo "Error: Number of chunks must be a positive integer"
    exit 1
fi

# Count total lines
TOTAL_LINES=$(wc -l < "$MERGED_FILE")
echo "Total lines in input file: $TOTAL_LINES"

# Calculate lines per chunk (rounded up)
LINES_PER_CHUNK=$(( (TOTAL_LINES + NUM_CHUNKS - 1) / NUM_CHUNKS ))
echo "Lines per chunk: $LINES_PER_CHUNK"
echo "Will create approximately $NUM_CHUNKS files"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Use split command with numeric suffixes
# -l: lines per file
# -d: use numeric suffixes instead of alphabetic
# -a: suffix length (calculate based on number of chunks)
SUFFIX_LENGTH=$(echo -n "$NUM_CHUNKS" | wc -c)
if [ "$SUFFIX_LENGTH" -lt 3 ]; then
    SUFFIX_LENGTH=4
fi

echo "Splitting file into $OUTPUT_DIR with prefix 'chunk_'..."
split -l "$LINES_PER_CHUNK" -d -a "$SUFFIX_LENGTH" "$MERGED_FILE" "$OUTPUT_DIR/chunk_"

# Rename files to add .txt extension
echo "Adding .txt extension to chunk files..."
for file in "$OUTPUT_DIR"/chunk_*; do
    if [ -f "$file" ]; then
        mv "$file" "${file}.txt"
    fi
done

# Count actual number of files created
ACTUAL_CHUNKS=$(ls -1 "$OUTPUT_DIR"/chunk_*.txt 2>/dev/null | wc -l)
echo ""
echo "Split complete!"
echo "Created $ACTUAL_CHUNKS chunk files in $OUTPUT_DIR"
echo "Each chunk has approximately $LINES_PER_CHUNK lines"

# Show some statistics
echo ""
echo "First chunk: $(ls -1 "$OUTPUT_DIR"/chunk_*.txt | head -1)"
echo "  Lines: $(wc -l < "$(ls -1 "$OUTPUT_DIR"/chunk_*.txt | head -1)")"
echo ""
echo "Last chunk: $(ls -1 "$OUTPUT_DIR"/chunk_*.txt | tail -1)"
echo "  Lines: $(wc -l < "$(ls -1 "$OUTPUT_DIR"/chunk_*.txt | tail -1)")"

# Create a manifest file
MANIFEST="$OUTPUT_DIR/manifest.txt"
echo "Creating manifest file: $MANIFEST"
ls -1 "$OUTPUT_DIR"/chunk_*.txt > "$MANIFEST"
echo "Manifest contains $ACTUAL_CHUNKS entries"

