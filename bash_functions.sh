#!/bin/bash

# .SYNOPSIS
#   Reliable clipboard transfer using the PSH|seq|hash|data protocol.
#   Compatible with PowerShell 5.1/7.0 Handshake.
# .DESCRIPTION
#   Monitors for 'PSH' packets and signals 'ACK' or 'FIN' to the sender.

receive_chunked_data() {
    # .SYNOPSIS: Uses 'read' for memory-efficient splitting to avoid string truncation.
    local out_file="$1"
    local last_idx="-1"
    local b64_buffer=""

    [[ -z "$out_file" ]] && { echo "Usage: receive_chunked_data <file>"; return 1; }
    echo -n "RDY" | xclip -selection clipboard

    while true; do
        # Get raw clipboard content into a variable
        # local raw
        raw=$(xclip -selection clipboard -o 2>/dev/null)
        
        # Immediate exit if clipboard isn't a PSH packet
        [[ "$raw" != PSH* ]] && { sleep 0.3; continue; }

        # Split string by pipe into an array
        # This handles newlines and massive strings better than regex
        IFS='|' read -r type idx hash data <<< "$raw"

        if [[ "$idx" != "$last_idx" && -n "$data" ]]; then
            # local cur_hash
            cur_hash=$(echo -n "$data" | sha256sum | cut -c1-8 | tr '[:lower:]' '[:upper:]')

            if [[ "$cur_hash" == "$hash" ]]; then
                b64_buffer+="$data"
                last_idx="$idx"
                
                local sig="ACK"
                [[ ${#data} -lt 100000 ]] && sig="FIN"
                
                echo -n "$sig" | xclip -selection clipboard
                echo "[OK] Received $idx -> $sig"
                
                if [[ "$sig" == "FIN" ]]; then
                    echo -n "$b64_buffer" | base64 -d > "$out_file"
                    echo "Success! Saved to $out_file"
                    break
                fi
            else
                echo "[!] Hash mismatch at $idx! Expected $hash, got $cur_hash"
            fi
        fi
        sleep 0.3
    done
}

send_chunked_data() {
    # .USAGE: send_chunked_data <file_path> [chunk_size]
    local file="$1"
    local chunk_size="${2:-100000}"

    [[ ! -f "$file" ]] && { echo "File not found: $file"; return 1; }

    echo "Encoding $file..."
    local b64
    b64=$(base64 -w 0 "$file")
    local len=${#b64}

    for (( i=0; i<len; i+=chunk_size )); do
        local chunk="${b64:$i:$chunk_size}"
        local hash
        hash=$(echo -n "$chunk" | sha256sum | cut -c1-8 | tr '[:lower:]' '[:upper:]')
        
        # Determine what signal we expect back
        local expected="ACK"
        [[ $((i + chunk_size)) -ge $len ]] && expected="FIN"

        echo -n "PSH|$i|$hash|$chunk" | xclip -selection clipboard
        echo "Sent $i. Waiting for $expected..."

        # Wait for PowerShell to echo the signal
        until [[ "$(xclip -selection clipboard -o 2>/dev/null)" == "$expected" ]]; do
            sleep 0.2
        done

        [[ "$expected" == "FIN" ]] && { echo "FIN received. Done!"; break; }
        
        # Set RDY to trigger the next PSH
        echo -n "RDY" | xclip -selection clipboard
    done
}