#!/usr/bin/env bash

PROGNAME="$0"                          # search for executable on path
PROGDIR=`dirname $PROGNAME`            # extract directory of program
PROGNAME=`basename $PROGNAME`          # base name of program
frame_width="20"
# Color threshold defines how many unique colors are needed to qualify an image
# as a photograph
color_threshold=16000

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

# Reduce DPI before processing the image to improve speed
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

# Store image information
read mime color_count opaque nw_color w h <<<$(identify -format '%m %k %[opaque] %[pixel: u.p{0,0}] %w %h' "$@")
wh="$w $h"

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

# Unify border width (if the border is not transparent)
if [[ "$nw_color" != 'none'
   && "$full_border" == 1 ]]; then
  # Trim the image and add a uniform frame
  # Note: -mattecolor may be interchangeable with -alpha-color
  mogrify \
    -mattecolor "${nw_color}" \
    -trim +repage \
    -frame "$frame_width" \
    "$@"
elif [[ "$nw_color" != 'none'
     && "$any_border" == 1 ]]; then

  # Top left pixel color applies to North and West sides
  nw_args="-background ${nw_color}"

  # Generate arguments for each side
  [[ $north_border == 1 ]] && nw_args="$nw_args -gravity north -splice x${frame_width}"
  [[ $west_border  == 1 ]] && nw_args="$nw_args -gravity west  -splice ${frame_width}x"
  [[ $south_border == 1 ]] && se_args="$se_args -gravity south -splice x${frame_width}"
  [[ $east_border  == 1 ]] && se_args="$se_args -gravity east  -splice ${frame_width}x"

  # If no north west border, use south east color
  if [[ $south_border == 1
     || $east_border  == 1  ]]; then
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
      north_count=$(( north_count - frame_width ))
    fi
    if [[ $south_border == 0 ]]; then
      rev_rows=( $(printf '%s\n' "${rows[@]}" | tail -r) )
      south_count=$(count_identical_pixels "${rev_rows[*]}")
      south_count=$(( south_count - frame_width ))
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
      west_count=$(( west_count - frame_width ))
    fi
    if [[ $east_border == 0 ]]; then
      rev_cols=( $(printf '%s\n' "${cols[@]}" | tail -r) )
      east_count=$(count_identical_pixels "${rev_cols[*]}")
      east_count=$(( east_count - frame_width ))
    fi
  fi

  # Generate chop string
  chop_args=''
  [[ $north_count > 0 ]] && chop_args="$chop_args -gravity north -chop 0x${north_count}"
  [[ $south_count > 0 ]] && chop_args="$chop_args -gravity south -chop 0x${south_count}"
  [[  $east_count > 0 ]] && chop_args="$chop_args -gravity east  -chop ${east_count}x0"
  [[  $west_count > 0 ]] && chop_args="$chop_args -gravity west  -chop ${west_count}x0"

  # Chop sides as needed
  mogrify $chop_args "$@"

  # Clean up temporary files
  rm -f $tmp/cols_*.mpc $tmp/cols_*.cache
  rm -rf $tmp
fi

# Convert to JPEG, if necessary
if   [[ $mime == 'PNG' ]]  \
  && (( $color_count > $color_threshold )) \
  && [[ $opaque == 'True' ]]; then
  mogrify -format jpg "$@" && rm "$@"
fi

# Reset dpi
#if [ $dpi -eq 144 ]; then
#  mogrify -density "$dpi" -units pixelsperinch "$@"
#fi
