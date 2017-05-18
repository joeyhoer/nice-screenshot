#!/usr/bin/env bash

PROGNAME="$0"                          # search for executable on path
PROGDIR=`dirname $PROGNAME`            # extract directory of program
PROGNAME=`basename $PROGNAME`          # base name of program
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

# Count the number of identical pixels (rows/columns) from the edge
# given an array of single pixel slices in an image
count_identical_pixels () {
  slices=( $1 )
  match="${slices[0]}"
  count=0
  for current in ${slices[@]}; do
    if [ `compare -dissimilarity-threshold 100% \
             -metric AE "$current" "$match" null: 2>&1` -eq 0 ]; then
      count=$(($count + 1))
    else
      break
    fi
  done
  echo "$count"
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

  # Detect repetitive, nonhomogenous sides…
  # This is slow and requires more disk space

  # Create temporary directoy for storing slices
  umask 77
  tmp=`mktemp -d "${TMPDIR:-/tmp}/$PROGNAME.XXXXXXXXXX"` ||
    { echo >&2 "$PROGNAME: Unable to create temporary file"; exit 10;}
  trap 'rm -rf "$tmp"' 0
  trap 'exit 2' 1 2 3 15

  # Read input image, once only as it may be pipelines, and save a MPC copy of
  # each individual row of pixels as temporary files
  convert "$1" -crop 0x1 +repage "$tmp/rows_%06d.mpc"

  # Look for repeated pixels on untrimmed sides, and
  # count the number of pixels to be added/removed to
  # equal the desired frame_width
  if [[ $north_border == 0 || $south_border == 0 ]]; then
    rows=( $tmp/rows_*.mpc )
    if [[ $north_border == 0 ]]; then
      north_count=$(count_identical_pixels "${rows[*]}")
      north_count=$(( frame_width - north_count ))
    fi
    if [[ $south_border == 0 ]]; then
      rev_rows=( $(printf '%s\n' "${rows[@]}" | tail -r) )
      south_count=$(count_identical_pixels "${rev_rows[*]}")
      south_count=$(( frame_width - south_count ))
    fi
  fi

  # Rejoin and re-split image into columns
  convert "$tmp/rows_*.mpc" -append +repage -crop 1x0 +repage "$tmp/cols_%06d.mpc"

  # Remove temporary row files to save disk space
  rm -f $tmp/rows_*.mpc $tmp/rows_*.cache

  # Look for repeated pixels on untrimmed sides, and
  # count the number of pixels to be added/removed to
  # equal the desired frame_width
  if [[ $west_border == 0 || $east_border == 0 ]]; then
    cols=( $tmp/cols_*.mpc )
    if [[ $west_border == 0 ]]; then
      west_count=$(count_identical_pixels "${cols[*]}")
      west_count=$(( frame_width - west_count ))
    fi
    if [[ $east_border == 0 ]]; then
      rev_cols=( $(printf '%s\n' "${cols[@]}" | tail -r) )
      east_count=$(count_identical_pixels "${rev_cols[*]}")
      east_count=$(( frame_width - east_count ))
    fi
  fi

  # Store the width and height of the image
  wh=$(identify -format '%w %h' "$@")
  read w h <<<$(echo "$wh")

  # Calculate final width and height
  final_width=$(( w + east_count + west_count ))
  final_height=$(( h + north_count + south_count ))

  # Chop/extend sides as needed
  if [[ $w != $final_width || $h != $final_height ]]; then
    # Generate crop string with offsets
    dimensions="${final_width}x${final_height}-$(( west_count ))-$(( north_count ))"

    # Alternatively use "chop" to remove a single side
    # e.g. chop_args="$chop_args -gravity North -chop 0x${chop}"
    mogrify \
      -set option:distort:viewport $dimensions \
      -virtual-pixel Edge -distort SRT 0 \
      "$@"
  fi

  # Clean up temporary files
  rm -f $tmp/cols_*.mpc $tmp/cols_*.cache
  rm -rf $tmp
fi

# Optimize image
# This strips dpi metadata
# image_optim --skip-missing-workers "$@"

# Reset dpi
#if [ $dpi -eq 144 ]; then
#  mogrify -density "$dpi" -units pixelsperinch "$@"
#fi
