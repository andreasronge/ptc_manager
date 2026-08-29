{
  remainder = $0

  while (match(remainder, /[^[:space:]]+[[:space:]]+\(ignore_errors=(yes|no)\)/)) {
    entry = substr(remainder, RSTART, RLENGTH)
    sub(/[[:space:]]+\(ignore_errors=(yes|no)\)$/, "", entry)
    print entry
    remainder = substr(remainder, RSTART + RLENGTH)
  }
}
