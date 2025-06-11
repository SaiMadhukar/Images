#!/usr/bin/env sh

# Image setup script for frozen-world.com
# This script creates directories and helps organize your car images

# Configuration
IMAGE_DIR="/var/www/images"
THUMB_DIR="/var/www/thumbnails"
API_DIR="/var/www/api"
ORIGINAL_DIR="/root/CarImages" # Change this to where your car images are located

MAPPING_FILE="$API_DIR/images.json"
TEMP_MAPPING_CSV="/tmp/image_mapping.csv"
EXISTING_HASH_ID_MAP_TEMP="/tmp/image_hash_id_map_existing.tmp"

# Add global variable for image size
default_resize_size="1024x768"
RESIZE_SIZE="$default_resize_size"

# Function to generate unique ID
generate_id() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 8
    else
        # Fallback for systems without openssl, more POSIX friendly
        # but might not be as robust for cryptographically strong randomnes
        # Consider 'uuidgen' if available, or a simpler timestamp+random_number
        head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-16
    fi
}

# Setup directories
configure_setup() {
    mkdir -p "$IMAGE_DIR" "$THUMB_DIR" "$API_DIR"
    chown -R nginx:nginx "$IMAGE_DIR" "$THUMB_DIR" "$API_DIR"
    chmod -R 755 "$IMAGE_DIR" "$THUMB_DIR" "$API_DIR"
    chmod 644 "$API_DIR"/*.json 2>/dev/null || true
}

# Process images
process_images() {
    [ ! -d "$ORIGINAL_DIR" ] && echo "Missing source dir: $ORIGINAL_DIR" && return 1
    # Ensure the temp file exists for grep later, even if mapping is missing or jq fails
    >"$EXISTING_HASH_ID_MAP_TEMP"
    if [ -f "$MAPPING_FILE" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.images[] | select(.hash) | "\(.hash) \(.id)"' "$MAPPING_FILE" > "$EXISTING_HASH_ID_MAP_TEMP"
    fi
    >"$TEMP_MAPPING_CSV" # Ensure it's empty before starting

    find "$ORIGINAL_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' \) | while read -r original_file; do
        [ ! -f "$original_file" ] && continue

        FILE_HASH=$(sha256sum "$original_file" | awk '{print $1}') # POSIX friendly
        EXT="webp"
        ORIGINAL_NAME=$(basename "$original_file")

        FOLDER_NAME=$(basename "$(dirname "$original_file")")
        [ -z "$FOLDER_NAME" ] && FOLDER_NAME="orphan"

        UNIQUE_ID=""
        if [ -s "$EXISTING_HASH_ID_MAP_TEMP" ]; then # Only grep if file has content
            EXISTING_ID_LINE=$(grep "^$FILE_HASH " "$EXISTING_HASH_ID_MAP_TEMP" | head -n 1)
            if [ -n "$EXISTING_ID_LINE" ]; then
                 UNIQUE_ID=$(echo "$EXISTING_ID_LINE" | awk '{print $2}')
            fi
        fi
        if [ -z "$UNIQUE_ID" ]; then
            UNIQUE_ID=$(generate_id)
        fi

        NEW_FILENAME="${UNIQUE_ID}.${EXT}"
        NEW_PATH="${IMAGE_DIR}/${NEW_FILENAME}"
        THUMB_PATH="${THUMB_DIR}/${UNIQUE_ID}.webp" # Thumbnails are now webp

        if [ ! -f "$NEW_PATH" ]; then
            # Print original size and file size
            orig_size="unknown"
            orig_kb="unknown"
            if command -v identify >/dev/null 2>&1; then
                orig_size=$(identify -format "%wx%h" "$original_file" 2>/dev/null || echo "unknown")
            fi
            if [ -f "$original_file" ]; then
                orig_kb=$(du -k "$original_file" | awk '{print $1}')
            fi
            if [ "$RESIZE_SIZE" = "original" ]; then
                if command -v magick >/dev/null 2>&1; then
                    magick "$original_file" "$NEW_PATH"
                elif command -v convert >/dev/null 2>&1; then
                    convert "$original_file" "$NEW_PATH"
                else
                    cp "$original_file" "$NEW_PATH"
                fi
            else
                if command -v magick >/dev/null 2>&1; then
                    magick "$original_file" -resize "$RESIZE_SIZE>" -background white -gravity center -extent "$RESIZE_SIZE" "$NEW_PATH"
                elif command -v convert >/dev/null 2>&1; then
                    convert "$original_file" -resize "$RESIZE_SIZE>" -background white -gravity center -extent "$RESIZE_SIZE" "$NEW_PATH"
                else
                    cp "$original_file" "$NEW_PATH"
                fi
            fi
            # Convert to webp if not already
            if command -v magick >/dev/null 2>&1; then
                magick "$NEW_PATH" "$NEW_PATH.webp" && mv "$NEW_PATH.webp" "$NEW_PATH"
            elif command -v convert >/dev/null 2>&1; then
                convert "$NEW_PATH" "$NEW_PATH.webp" && mv "$NEW_PATH.webp" "$NEW_PATH"
            fi
            # Print new size and file size
            new_size="unknown"
            new_kb="unknown"
            if command -v identify >/dev/null 2>&1; then
                new_size=$(identify -format "%wx%h" "$NEW_PATH" 2>/dev/null || echo "unknown")
            fi
            if [ -f "$NEW_PATH" ]; then
                new_kb=$(du -k "$NEW_PATH" | awk '{print $1}')
            fi
            echo "[DEBUG] $ORIGINAL_NAME: $orig_size (${orig_kb}KB) -> $new_size (${new_kb}KB)"
        fi

        # Generate webp thumbnail with the same filename as the main image
        if command -v magick >/dev/null 2>&1; then
            magick "$NEW_PATH" -resize 300x300^ -gravity center -extent 300x300 "$THUMB_PATH" 2>/dev/null
        elif command -v convert >/dev/null 2>&1; then # Fallback to 'convert' if 'magick' not found
            convert "$NEW_PATH" -resize 300x300^ -gravity center -extent 300x300 "$THUMB_PATH" 2>/dev/null
        else
            echo "Warning: ImageMagick (magick or convert) not found. Thumbnail not generated for $NEW_FILENAME" >&2
        fi

        echo "$UNIQUE_ID,$ORIGINAL_NAME,$NEW_FILENAME,$EXT,$FILE_HASH,$FOLDER_NAME" >> "$TEMP_MAPPING_CSV"
    done

    if [ -s "$TEMP_MAPPING_CSV" ]; then # Only proceed if CSV has data
      generate_json_mapping && upload_json_to_postgres
    fi
    rm -f "$EXISTING_HASH_ID_MAP_TEMP"
}

generate_json_mapping() {
    cat > /tmp/generate_json.py << 'EOF'
import csv, json, os, sys
from datetime import datetime

images, processed_hashes = [], set()
try:
    with open('/tmp/image_mapping.csv', 'r') as f:
        for row in csv.reader(f):
            if len(row) == 6:
                unique_id, original_name, filename, ext, file_hash, folder_name = row
                if file_hash not in processed_hashes:
                    images.append({
                        "id": unique_id,
                        "original_name": original_name,
                        "filename": filename,
                        "extension": ext,
                        "url": f"/{folder_name}/{unique_id}", # Assumes URL structure, might need base URL
                        "direct_url": f"/{folder_name}/{unique_id}.{ext}", # Assumes URL structure
                        "thumbnail_url": f"/thumbnails/{unique_id}.{ext}", # Thumbnails match main image name
                        "hash": file_hash,
                        "folder": folder_name
                    })
                    processed_hashes.add(file_hash)
except FileNotFoundError:
    sys.stderr.write(f"Error: CSV file /tmp/image_mapping.csv not found.\n"); sys.exit(1)
except Exception as e:
    sys.stderr.write(f"CSV Read Error: {e}\n"); sys.exit(1)

try:
    with open('/var/www/api/images.json', 'w') as f:
        json.dump({
            "images": images,
            "total": len(images),
            "generated_at": datetime.utcnow().isoformat() + "Z"
        }, f, indent=2)
    os.chmod('/var/www/api/images.json', 0o644)
except Exception as e:
    sys.stderr.write(f"JSON Write Error: {e}\n"); sys.exit(1)
EOF

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: python3 is not installed. Cannot generate JSON mapping." >&2
        return 1
    fi
    if python3 /tmp/generate_json.py; then
        chown nginx:nginx "$MAPPING_FILE" 2>/dev/null || true # Allow failure if not root
        chmod 644 "$MAPPING_FILE" 2>/dev/null || true
    else
        echo "Error: Python script for JSON generation failed." >&2
        # Retain TEMP_MAPPING_CSV for debugging if python script fails
        # rm -f /tmp/generate_json.py # Clean up python script anyway
        return 1
    fi
    rm -f "$TEMP_MAPPING_CSV" /tmp/generate_json.py
}

upload_json_to_postgres() {
    echo "Uploading JSON mapping to PostgreSQL..."

    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: 'jq' is not installed. Please install it to proceed." >&2
        return 1
    fi
    if ! command -v psql >/dev/null 2>&1; then
        echo "Error: 'psql' is not installed. Please install it to proceed." >&2
        return 1
    fi

    # Ensure these are set, possibly from environment variables or a config file
    PGHOST="${PGHOST:-localhost}"
    PGPORT="${PGPORT:-5432}"
    PGUSER="${PGUSER:-postgres}"
    PGDATABASE="${PGDATABASE:-carspace}" # Placeholder - Set your DB name

    # Check PostgreSQL connectivity
    if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "\q" >/dev/null 2>&1; then
        echo "Error: Unable to connect to PostgreSQL database '$PGDATABASE' as user '$PGUSER' at $PGHOST:$PGPORT." >&2
        echo "Please check your connection settings, ensure PostgreSQL is running, and that the user/database exists." >&2
        # You might want to include details on how to set PGPASSWORD if not using .pgpass or other auth methods
        return 1
    fi

    # Create table if it doesn't exist
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "
    CREATE TABLE IF NOT EXISTS CarImages (
      Make TEXT NOT NULL,
      Model TEXT,
      Year INTEGER,
      ID TEXT UNIQUE NOT NULL,
      URL TEXT NOT NULL,
      PRIMARY KEY (Make, ID)
    );"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create table CarImages." >&2
        return 1
    fi

    jq -c '.images[]' "$MAPPING_FILE" | while read -r image; do
        ID=$(echo "$image" | jq -r '.id')
        URL=$(echo "$image" | jq -r '.direct_url')
        ORIGINAL_NAME=$(echo "$image" | jq -r '.original_name')
        FOLDER=$(echo "$image" | jq -r '.folder') # This is Make

        # BASENAME is ORIGINAL_NAME without path, ORIGINAL_NAME is already a basename
        # NAME_PART is BASENAME without extension
        NAME_PART=$(echo "$ORIGINAL_NAME" | sed 's/\.[^.]*$//')

        # POSIX-compliant way to split NAME_PART into Model and YearJunk
        # Assumes NAME_PART is like "Model_YearExtra" or just "Model"
        Model="${NAME_PART%%_*}" # Gets content before the first '_'
        if [ "$NAME_PART" = "$Model" ]; then
            # No underscore found, so NAME_PART is the Model, YearJunk is empty
            YearJunk=""
        else
            YearJunk="${NAME_PART#*_}" # Gets content after the first '_'
        fi

        # Sanitize Model: remove non-alphanumeric characters
        Model=$(echo "$Model" | sed 's/[^a-zA-Z0-9]//g')

        # Extract 4-digit year from YearJunk.
        # Note: grep -o is a GNU extension. For strict POSIX, use sed:
        # Year=$(echo "$YearJunk" | sed -n 's/.*\([0-9]\{4\}\).*/\1/p' | head -n 1)
        Year=$(echo "$YearJunk" | grep -o '[0-9]\{4\}' | head -n 1) # head -n 1 to ensure only one year if multiple 4-digit numbers present

        if [ -z "$FOLDER" ]; then
            FOLDER="orphan" # Default 'Make' if folder was empty
        fi

        # Prepare SQL: Use ${Year:-NULL} for an SQL NULL if Year is empty
        SQL_YEAR_VALUE="NULL"
        if [ -n "$Year" ]; then
            SQL_YEAR_VALUE="$Year"
        fi

        SQL="INSERT INTO CarImages (Make, Model, Year, ID, URL)
        VALUES ('$FOLDER', '$Model', $SQL_YEAR_VALUE, '$ID', '$URL')
        ON CONFLICT (Make, ID) DO UPDATE
        SET Model = EXCLUDED.Model,
            Year = EXCLUDED.Year,
            URL = EXCLUDED.URL;"

        if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "$SQL"; then
            echo "Warning: Failed to execute SQL for ID $ID. SQL was:" >&2
            echo "$SQL" >&2
            # Consider whether to continue or stop on error
        fi
    done

    echo "Upload completed."
}

# Function to remove all images with confirmation
delete_all_images() {
    local img_dir="$1"
    local thumb_dir="$2"
    echo "WARNING: This will delete ALL images in $img_dir and $thumb_dir and remove all image records from the database."
    printf "Are you sure you want to proceed? Type 'YES' to confirm: "
    read -r confirm
    if [ "$confirm" = "YES" ]; then
        echo "Deleting all images in $img_dir and $thumb_dir..."
        rm -rf "$img_dir"/* "$thumb_dir"/*
        echo "All images deleted."
        # Remove all image records from the database
        PGHOST="${PGHOST:-localhost}"
        PGPORT="${PGPORT:-5432}"
        PGUSER="${PGUSER:-postgres}"
        PGDATABASE="${PGDATABASE:-carspace}"
        if command -v psql >/dev/null 2>&1; then
            echo "Deleting all image records from the CarImages table..."
            psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "DELETE FROM CarImages;"
            echo "All image records deleted from the database."
        else
            echo "Warning: 'psql' is not installed. Database records were not deleted." >&2
        fi
    else
        echo "Aborted. No images or database records were deleted."
    fi
}

delete_one_image() {
    local image_id="$1"
    if [ -z "$image_id" ]; then
        echo "Error: No image ID provided. Usage: $0 delete-one <image_id>" >&2
        return 1
    fi
    # Remove image and thumbnail files
    img_file=$(find "$IMAGE_DIR" -type f -name "$image_id.*" | head -n 1)
    thumb_file="$THUMB_DIR/$image_id.webp"
    if [ -f "$img_file" ]; then
        rm -f "$img_file"
        echo "Deleted image file: $img_file"
    else
        echo "Image file for ID $image_id not found in $IMAGE_DIR."
    fi
    if [ -f "$thumb_file" ]; then
        rm -f "$thumb_file"
        echo "Deleted thumbnail: $thumb_file"
    fi
    # Remove from mapping file (images.json)
    if [ -f "$MAPPING_FILE" ] && command -v jq >/dev/null 2>&1; then
        tmp_json="${MAPPING_FILE}.tmp"
        jq --arg id "$image_id" 'del(.images[] | select(.id == $id)) | .images |= map(select(.id != $id)) | .total = (.images | length)' "$MAPPING_FILE" > "$tmp_json" && mv "$tmp_json" "$MAPPING_FILE"
        echo "Removed image ID $image_id from $MAPPING_FILE."
    fi
    # Remove from database
    PGHOST="${PGHOST:-localhost}"
    PGPORT="${PGPORT:-5432}"
    PGUSER="${PGUSER:-postgres}"
    PGDATABASE="${PGDATABASE:-carspace}"
    if command -v psql >/dev/null 2>&1; then
        psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "DELETE FROM CarImages WHERE ID = '$image_id';"
        echo "Removed image ID $image_id from database."
    fi
}

# Main execution
# Check for required commands early
missing_cmds=""
for cmd in find basename dirname sha256sum awk tr grep head cat python3 jq psql sed cp mkdir chown chmod rm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing_cmds="$missing_cmds $cmd"
    fi
done

if [ -n "$missing_cmds" ]; then
    echo "Error: The following required commands are not found in your PATH: $missing_cmds" >&2
    exit 1
fi

# Argument parsing and main logic
case "$1" in
  delete-all)
    delete_all_images "$IMAGE_DIR" "$THUMB_DIR"
    # Also remove mapping file
    if [ -f "$MAPPING_FILE" ]; then
      rm -f "$MAPPING_FILE"
      echo "Mapping file $MAPPING_FILE deleted."
    fi
    ;;
  delete-one)
    if [ -z "$2" ]; then
      echo "Usage: $0 delete-one <image_id>" >&2
      exit 1
    fi
    delete_one_image "$2"
    ;;
  help)
    echo "Usage: $0 [process [source_folder]|delete-all|delete-one <image_id>|help]"
    echo "  process [source_folder] - Process and import images from source_folder (default: $ORIGINAL_DIR)"
    echo "  delete-all - Delete all images, mapping file, and database records (confirmation required)"
    echo "  delete-one <image_id> - Delete a specific image by ID from all locations"
    echo "  help       - Show this help message"
    ;;
  process|"")
    if [ -n "$2" ]; then
      ORIGINAL_DIR="$2"
    else
      printf "Enter the source folder path to process images (default: $ORIGINAL_DIR): "
      read -r input_dir
      if [ -n "$input_dir" ]; then
        ORIGINAL_DIR="$input_dir"
      fi
    fi
    # Prompt for image size
    echo "Choose image size for processing:"
    echo "  1) original (no resize)"
    echo "  2) logo    (250x150)"
    echo "  3) small   (512x512)"
    echo "  4) medium  (1200x800)"
    echo "  5) large   (1280x1920)"
    printf "Enter choice [1-5] (default: 4): "
    read -r size_choice
    case "$size_choice" in
      1)
        RESIZE_SIZE="original"
        ;;
      2)
        RESIZE_SIZE="250x150"
        ;;
      3)
        RESIZE_SIZE="512x512"
        ;;
      4|"")
        RESIZE_SIZE="1200x800"
        ;;
      5)
        RESIZE_SIZE="1280x1920"
        ;;
      *)
        echo "Invalid choice. Using default (1200x800)."
        RESIZE_SIZE="1200x800"
        ;;
    esac
    configure_setup
    process_images
    ;;
  *)
    echo "Unknown argument: $1"
    echo "Use '$0 help' for usage."
    exit 1
    ;;
esac

echo "Script finished."