#!/bin/bash

# --- Configuration ---
OUTPUT_MP4="output.mp4"
FILE_LIST="files.txt"
DOWNLOAD_DIR="ts_parts" # Directory to save the downloaded .ts files

# --- Prompt for curl command ---
echo "Please paste the complete curl command (including '\\' for line continuation) and press Enter when done."
echo "Press Ctrl+D on a new line to finish input."

CURL_COMMAND=""
while IFS= read -r line; do
    CURL_COMMAND="$CURL_COMMAND"$'\n'"$line"
done

# Remove the initial empty line if one was captured
CURL_COMMAND=$(echo "$CURL_COMMAND" | sed '1{/^$/d;}')

# --- Parse curl command ---
echo "Parsing curl command..."

# Extract the main URL (assumes it's the first quoted string after 'curl ')
# This is a simplified approach and might need adjustment based on curl output variations
MAIN_URL=$(echo "$CURL_COMMAND" | grep -oP "curl '\K[^']+" | head -n 1)

if [ -z "$MAIN_URL" ]; then
    echo "Error: Could not extract main URL from curl command."
    exit 1
fi

# Extract Headers (-H 'Header: Value')
HEADERS=()
# Use grep to find lines starting with -H ' and extract the content within single quotes
while read -r header_line; do
    # Extract content within single quotes after -H
    header_value=$(echo "$header_line" | sed -n "s/^.*-H '\(.*\)'[^']*$/\1/p")
    if [ -n "$header_value" ]; then
        HEADERS+=("$header_value")
    fi
done < <(echo "$CURL_COMMAND" | grep " -H '")


if [ ${#HEADERS[@]} -eq 0 ]; then
    echo "Warning: No headers extracted from curl command."
fi


# Extract Cookies (-b 'Cookie: Value')
COOKIES=$(echo "$CURL_COMMAND" | grep -oP " -b '\K[^']+")

if [ -z "$COOKIES" ]; then
    echo "Warning: No cookies extracted from curl command."
fi

echo "Extracted URL: $MAIN_URL"
echo "Extracted Headers Count: ${#HEADERS[@]}"
echo "Extracted Cookies: ${COOKIES:0:50}..." # Show only first 50 chars of cookies


# --- Parse URL to get Base URL and Starting Number ---
# Use sed to remove the number and .ts extension at the end
BASE_URL=$(echo "$MAIN_URL" | sed 's|_[0-9]\+\.ts$|_|')

# Use sed to extract the number before .ts
START_NUM_STR=$(echo "$MAIN_URL" | sed 's|^.*_\([0-9]\+\)\.ts$|\1|')

# Determine the number of digits from the starting number string
NUM_DIGITS=${#START_NUM_STR}

# Convert the starting number string to an integer
CURRENT_NUM=$((10#$START_NUM_STR)) # Use 10# to ensure base 10 interpretation

echo "Detected Base URL: ${BASE_URL}"
echo "Starting from segment number: ${START_NUM_STR} (${NUM_DIGITS} digits)"


# --- Create download directory ---
mkdir -p "$DOWNLOAD_DIR"

# --- Download the .ts files ---
echo "Attempting to download .ts files sequentially..."
DOWNLOADED_FILES=() # Array to store paths of successfully downloaded files

while true; do
    # Format the current number with leading zeros
    FORMATTED_NUM=$(printf "%0${NUM_DIGITS}d" $CURRENT_NUM)
    FILE_URL="${BASE_URL}${FORMATTED_NUM}.ts"
    OUTPUT_FILE="${DOWNLOAD_DIR}/${FORMATTED_NUM}.ts"

    echo "Checking: ${FILE_URL}"

    # Construct the curl command with extracted headers and cookies to check existence
    curl_check_cmd="curl -I --silent --fail \"$FILE_URL\""
    for header in "${HEADERS[@]}"; do
        # Ensure headers with spaces or special chars are quoted correctly
        curl_check_cmd+=" -H '$header'"
    done
    if [ -n "$COOKIES" ]; then
      curl_check_cmd+=" -b '$COOKIES'"
    fi


    # Execute the curl check command
    eval "$curl_check_cmd"

    if [ $? -eq 0 ]; then
        # File exists, now download it
        echo "Found, downloading: ${FILE_URL}"
        curl_download_cmd="curl -o \"$OUTPUT_FILE\" \"$FILE_URL\""
         for header in "${HEADERS[@]}"; do
            curl_download_cmd+=" -H '$header'"
        done
        if [ -n "$COOKIES" ]; then
          curl_download_cmd+=" -b '$COOKIES'"
        fi


        eval "$curl_download_cmd"

        if [ $? -eq 0 ]; then
            DOWNLOADED_FILES+=("$OUTPUT_FILE") # Add to list of successful downloads
            CURRENT_NUM=$((CURRENT_NUM + 1)) # Move to the next number
        else
            echo "Error downloading ${FILE_URL}. Stopping sequence check."
            break # Stop if a download fails even after check
        fi
    else
        echo "File not found or error accessing ${FILE_URL} (likely 404). Stopping sequence check."
        break # Stop loop if curl --fail returns non-zero (404 or other error)
    fi
done

# --- Check if any files were downloaded ---
if [ ${#DOWNLOADED_FILES[@]} -eq 0 ]; then
    echo "No files were successfully downloaded."
    exit 1
fi

# --- Create file list for ffmpeg ---
echo "Creating file list for ffmpeg..."
> "$FILE_LIST" # Clear the file list
for file in "${DOWNLOADED_FILES[@]}"; do
    echo "file '$file'" >> "$FILE_LIST"
done

# --- Concatenate using ffmpeg ---
echo "Concatenating ${#DOWNLOADED_FILES[@]} .ts files into ${OUTPUT_MP4} using ffmpeg..."
# Check if files were actually downloaded and are larger than 1KB before concatenating
if find "$DOWNLOAD_DIR" -maxdepth 1 -type f -size +1k -print -quit | grep -q .; then
    ffmpeg -f concat -safe 0 -i "$FILE_LIST" -c copy "$OUTPUT_MP4"
    if [ $? -ne 0 ]; then
        echo "FFmpeg concatenation failed."
        # You might want to inspect the individual .ts files for corruption here
    fi
else
    echo "Downloaded files in ${DOWNLOAD_DIR} are 1KB or smaller. Download likely failed to get actual content."
fi


# --- Clean up downloaded .ts files and file list (optional) ---
# echo "Cleaning up downloaded .ts files and file list..."
# rm -rf "$DOWNLOAD_DIR" "$FILE_LIST"

echo "Process complete (check for FFmpeg errors above)."