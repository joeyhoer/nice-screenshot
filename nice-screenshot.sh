#!/usr/bin/env bash

frame_width="20"

# Determine if a side of an image is trimmable
# Return "0" if the side can be trimmed
test_trim () {
  direction="$1"
  expected_size="$2"
  image="$3"

  # Get the opposite side, which should be avoided in testing
  case "$direction" in
    North) avoid="South" ;;
    South) avoid="North" ;;
    East) avoid="West" ;;
    West) avoid="East" ;;
  esac

  # Get the axis on which to add pixels to avoid accidental trimming
  pixels="1x0"
  if [ "$direction" = "North" ] || [ "$direction" = "South" ]; then
    pixels="0x1"
  fi

  # Get size
  # Add pixels to the *opposite* side to avoid accidental trimming
  size=$(convert "$image" -gravity "$avoid" \
       -background white -splice "$pixels" -background black -splice "$pixels" \
       -trim +repage -chop "$pixels" -ping -format '%w %h' info:)

  # If the width and height are equal to the original width and height,
  # the side could not be trimmed and the image is ineligible for trimming
  [[ "$size" != "$expected_size" ]] && printf 1 || printf 0
}

# Store image metadata
info=$(sips -g dpiWidth -g pixelWidth "$@")
dpi=$(echo "$info" | awk '$1 ~ /dpiWidth/ { print $2/1 }')
width=$(echo "$info" | awk '$1 ~ /pixelWidth/ { print $2/2 }')

# Reduce DPI
if [ $dpi -eq 144 ]; then
  # When reducing an image:
  #   -scale  == -resize box, but faster
  #   -sample == -resize point, but much faster
  #   -resize is slower, but can be combined with -filter
  #     to produce different results
  mogrify \
    -scale 50%  \
    -density 72 -units pixelsperinch \
    "$@"

  # Convert to progressive JPG with white background
  # Caution: This creates a new file, which may be processed seperately
  #   -format jpg -interlace Plane -background white -alpha remove \
  # Remove original image
  #   ephemeral:"$@"

  # Alternative downsampling method
  #sips --resampleWidth "$width" "$@"
fi

# Store the width and height of the image
wh=$(identify -format '%w %h' "$@")

# Determine which sides of the image are solid borders which can be trimmed
north_border=$(test_trim North "$wh" "$@")
south_border=$(test_trim South "$wh" "$@")
east_border=$(test_trim East "$wh" "$@")
west_border=$(test_trim West "$wh" "$@")

# Determine if any or all sides are borders
full_border=0
any_border=0
if [[
    $north_border == 1 &&
    $south_border == 1 &&
    $east_border  == 1 &&
    $west_border  == 1 ]]; then
  full_border=1
elif [[
    $north_border == 1 ||
    $south_border == 1 ||
    $east_border  == 1 ||
    $west_border  == 1 ]]; then
  any_border=1
fi

# Store top left pixel color
color=$(identify -format "%[pixel: u.p{0,0}]" "$@")

# Unify border width (if the border is not transparent)
if [[ "$color" != 'none'
   && "$full_border" == 1 ]]; then
  # Trim the image and add a uniform frame
  # Note: -mattecolor may be interchangeable with -alpha-color
  mogrify \
    -mattecolor "${color}" \
    -trim +repage \
    -frame "$frame_width" \
    "$@"
elif [[ "$color" != 'none'
     && "$any_border" == 1 ]]; then

  # Top left pixel color applies to North and West sides
  nw_args="-background ${color}"

  # Generate arguments for each side
  [[ $north_border == 1 ]] && nw_args="$nw_args -gravity north -splice x${frame_width}"
  [[ $west_border  == 1 ]] && nw_args="$nw_args -gravity west  -splice ${frame_width}x"
  [[ $south_border == 1 ]] && se_args="$se_args -gravity south -splice x${frame_width}"
  [[ $east_border  == 1 ]] && se_args="$se_args -gravity east  -splice ${frame_width}x"

  # If no north west border, use south east color
  if [[ $south_border == 1
     || $east_border  == 1  ]]; then
      read w h <<<$(echo "$wh")
      # Store bottom right pixel color
      se_color=$(identify -format "%[pixel: u.p{$(($w-1)),$(($h-1))}]" "$@")
      # Bottom right pixel color applies to South and East sides
      se_args="-background ${se_color} $se_args"
  fi

  # Trim the image and frame each side individaully
  mogrify -trim +repage $nw_args $se_args "$@"
fi

# Optimize image
# This strips dpi metadata
# image_optim --skip-missing-workers "$@"

# Reset dpi
#if [ $dpi -eq 144 ]; then
#  mogrify -density "$dpi" -units pixelsperinch "$@"
#fi
