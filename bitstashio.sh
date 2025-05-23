#!/bin/bash

# --- Configuration ---
FILE_LIST="files.txt"
DOWNLOAD_DIR="ts_parts" # Directory to save the downloaded .ts files
OUTPUT_MP4="" # Will be set after parsing the URL
M3U8_URL="" # Will be set if -m flag is used

# --- Command line arguments ---
while getopts "m:" opt; do
    case $opt in
        m)
            M3U8_URL="$OPTARG"
            ;;
        \?)
            echo "Invalid option: -$OPTARG"
            exit 1
            ;;
    esac
done

# >>> NEW CONFIGURATION FOR PARSING SEGMENT NUMBER <<<
# Define a regular expression to find the segment number in the URL.
# The actual segment number MUST be inside a CAPTURE GROUP ()
# Examples:
# For URL like ..._1080_00001.ts    -> SEGMENT_REGEX='_1080_([0-9]+)\.ts$'
# For URL like ..._00001.ts         -> SEGMENT_REGEX='_([0-9]+)\.ts$'
# For URL like .../seg_00001.ts     -> SEGMENT_REGEX='seg_([0-9]+)\.ts$'
# You MUST set this correctly based on your URL structure.
SEGMENT_REGEX='_([0-9]+)\.ts$' # <--- ADJUST THIS REGEX IF YOUR URL IS DIFFERENT

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


# --- Parse URL to get Base URL and Starting Number using SEGMENT_REGEX ---
# Extract the segment number string using the defined regex capture group
START_NUM_STR=$(echo "$MAIN_URL" | grep -oP "$SEGMENT_REGEX" | grep -oP '\d+')

if [ -z "$START_NUM_STR" ]; then
    echo "Could not automatically detect segment number pattern."
    echo "Please enter:"
    echo "1. The base URL (everything before the changing number)"
    echo "2. The starting number"
    echo "3. The suffix (everything after the number)"
    read -p "Base URL: " BASE_URL
    read -p "Starting number: " START_NUM_STR
    read -p "Suffix (e.g. -v1-a1.ts): " FILE_SUFFIX
    
    if [[ ! "$START_NUM_STR" =~ ^[0-9]+$ ]]; then
        echo "Error: Starting number must be numeric"
        exit 1
    fi
    
    # Set output name based on the last part of the base URL
    BASE_NAME=$(basename "$BASE_URL" | sed 's/_*$//')
    OUTPUT_MP4="${BASE_NAME}.mp4"
    
    echo "Output will be saved as: $OUTPUT_MP4"
fi

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
    FILE_URL="${BASE_URL}${FORMATTED_NUM}${FILE_SUFFIX}"
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

fi # End of the if [ "$goto_ffmpeg" -eq 0 ] block

# --- Handle M3U8 if provided ---
if [ ! -z "$M3U8_URL" ]; then
    echo "M3U8 URL provided. Attempting to parse playlist..."
    
    # Create a temporary file for the m3u8 content
    M3U8_TEMP=$(mktemp)
    
    # Download the m3u8 file
    if ! curl -s "$M3U8_URL" > "$M3U8_TEMP"; then
        echo "Failed to download M3U8 playlist"
        rm "$M3U8_TEMP"
        exit 1
    fi
    
    # Get the base URL for the ts files
    M3U8_BASE_URL=$(dirname "$M3U8_URL")
    
    # Parse the m3u8 file for .ts files
    TS_URLS=()
    while IFS= read -r line; do
        # Skip lines starting with # (comments/directives)
        [[ $line =~ ^# ]] && continue
        # Skip empty lines
        [ -z "$line" ] && continue
        
        # If line ends with .ts, it's a segment
        if [[ $line == *".ts" ]]; then
            # Handle both absolute and relative URLs
            if [[ $line == http* ]]; then
                TS_URLS+=("$line")
            else
                TS_URLS+=("$M3U8_BASE_URL/$line")
            fi
        fi
    done < "$M3U8_TEMP"
    
    # Clean up temp file
    rm "$M3U8_TEMP"
    
    # Set the output name based on the m3u8 filename if not already set
    if [ -z "$OUTPUT_MP4" ]; then
        OUTPUT_MP4=$(basename "$M3U8_URL" .m3u8).mp4
    fi
    
    echo "Found ${#TS_URLS[@]} segments in playlist"
    echo "Output will be saved as: $OUTPUT_MP4"
    
    # Create download directory
    mkdir -p "$DOWNLOAD_DIR"
    
    # Download the segments
    DOWNLOADED_FILES=()
    for ((i=0; i<${#TS_URLS[@]}; i++)); do
        url="${TS_URLS[$i]}"
        OUTPUT_FILE="${DOWNLOAD_DIR}/$(printf "%05d" $i).ts"
        echo "Downloading segment $((i+1))/${#TS_URLS[@]}: $url"
        
        # Use curl with the same headers/cookies as main script
        curl_download_cmd="curl -o \"$OUTPUT_FILE\" \"$url\""
        for header in "${HEADERS[@]}"; do
            curl_download_cmd+=" -H '$header'"
        done
        if [ -n "$COOKIES" ]; then
            curl_download_cmd+=" -b '$COOKIES'"
        fi
        
        eval "$curl_download_cmd"
        
        if [ $? -eq 0 ]; then
            DOWNLOADED_FILES+=("$OUTPUT_FILE")
        else
            echo "Error downloading segment $((i+1))"
            continue
        fi
    done
    
    # m3u8 processing complete
fi