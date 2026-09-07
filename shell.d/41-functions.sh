# Handy shell functions (adopted from hamvocke/dotfiles).

# Find out what's running on a given TCP port: whatsonport 8080
whatsonport() {
  lsof -i "tcp:$1"
}

# Decode a JWT's header and payload: jwtdecode <token>
jwtdecode() {
  echo "$1" | jq -R 'split(".") | .[0],.[1] | @base64d | fromjson'
}

# Convert images to a single PDF (needs imagemagick): img2pdf "2025-01-*" out.pdf
img2pdf() {
  magick "$1" -auto-orient "$2"
}
