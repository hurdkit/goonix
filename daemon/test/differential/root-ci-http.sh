#!/bin/sh
# Serve one file over HTTP/1.0 (for builtin:download).  Args: FILE
file=$1
len=$(wc -c < "$file")
printf 'HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$len"
cat "$file"