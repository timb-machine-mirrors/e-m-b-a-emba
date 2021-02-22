#!/bin/bash

# emba - EMBEDDED LINUX ANALYZER
#
# Copyright 2020-2021 Siemens Energy AG
# Copyright 2020-2021 Siemens AG
#
# emba comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# emba is licensed under GPLv3
#
# Author(s): Michael Messner, Pascal Eckmann

P05_firmware_bin_extractor() {
  module_log_init "${FUNCNAME[0]}"
  module_title "Binary firmware extractor"

  mkdir "$LOG_DIR"/extractor/ 2>/dev/null

  # we love binwalk ... this is our first chance for extracting everything
  binwalking

  LINUX_PATH_COUNTER="$(find "$OUTPUT_DIR_binwalk" "${EXCL_FIND[@]}" -type d -iname bin -o -type f -iname busybox -o -type d -iname sbin -o -type d -iname etc 2> /dev/null | wc -l)"

  # if we have not found a linux filesystem we try to extract the firmware again with FACT-extractor
  if [[ $LINUX_PATH_COUNTER -lt 2 && $FACT_EXTRACTOR -eq 1 ]] ; then
    fact_extractor
  fi

  FILES_BINWALK=$(find "$OUTPUT_DIR_binwalk" -type f | wc -l )
  if [[ -n "$OUTPUT_DIR_fact" ]]; then
    FILES_FACT=$(find "$OUTPUT_DIR_fact" -type f | wc -l )
  fi

  LINUX_PATH_COUNTER="$(find "$OUTPUT_DIR_binwalk" "${EXCL_FIND[@]}" -type d -iname bin -o -type f -iname busybox -o -type d -iname sbin -o -type d -iname etc 2> /dev/null | wc -l)"

  print_output "[*] Default binwalk extractor extracted $FILES_BINWALK files."
  if [[ -n $FILES_FACT ]]; then
    print_output "[*] Default FACT-extractor extracted $FILES_FACT files."
  fi

  # if we have not found a linux filesystem we try to do a binwalk -e -M on every file
  if [[ $DEEP_EXTRACTOR -eq 1 ]] ; then
    deep_extractor
  fi

  BINS=$(find "$LOG_DIR"/extractor/ "${EXCL_FIND[@]}" -type f -executable | wc -l )
  UNIQUE_BINS=$(find "$LOG_DIR"/extractor/ "${EXCL_FIND[@]}" -type f -executable -exec md5sum {} \; | sort -u -k1,1 | wc -l )
  print_output "[*] Found $BINS executables."
  print_output "[*] Using $UNIQUE_BINS unique executables."
}

deep_extractor() {
  sub_module_title "Walking through all files and try to extract what ever possible"
  print_output "[*] Deep extraction with binwalk - 1st round"

  FILES_BEFORE_DEEP=$(find "$LOG_DIR"/extractor/ -type f | wc -l )
  find "$LOG_DIR"/extractor/ -type f -exec binwalk -e -M {} \;

  print_output "[*] Deep extraction with binwalk - 2nd round"
  find "$LOG_DIR"/extractor/ -type f -exec binwalk -e -M {} \;
  FILES_AFTER_DEEP=$(find "$LOG_DIR"/extractor/ -type f | wc -l )

  print_output "[*] Before deep extraction we had $FILES_BEFORE_DEEP files, after deep extraction we have now $FILES_AFTER_DEEP files extracted."
}

fact_extractor() {
  sub_module_title "Extracting binary firmware blob with FACT-extractor"

  export OUTPUT_DIR_fact
  OUTPUT_DIR_fact=$(basename "$FIRMWARE_PATH")
  OUTPUT_DIR_fact="$LOG_DIR"/extractor/"$OUTPUT_DIR_fact"_fact_emba

  print_output "[*] Extracting firmware to directory $OUTPUT_DIR_fact"

  print_output "$(./external/extract.py -o "$OUTPUT_DIR_fact" "$FIRMWARE_PATH" 2>/dev/null)"
}

binwalking() {
  sub_module_title "Analyze binary firmware blob with binwalk"

  print_output "[*] basic analysis with binwalk"
  #print_output "$(binwalk "$FIRMWARE_PATH")"
  mapfile -t BINWALK_OUTPUT < <(binwalk "$FIRMWARE_PATH")
  if [[ ${#BINWALK_OUTPUT[@]} -ne 0 ]] ; then
    for LINE in "${BINWALK_OUTPUT[@]}" ; do
      print_output "$LINE"
    done
  fi

  echo
  print_output "[*] Entropy testing with binwalk ... "
  print_output "$(binwalk -E -F -J "$FIRMWARE_PATH")"
  mv "$(basename "$FIRMWARE_PATH".png)" "$LOG_DIR"/"$(basename "$FIRMWARE_PATH"_entropy.png)" 2> /dev/null
  if command -v xdg-open > /dev/null; then
    xdg-open "$LOG_DIR"/"$(basename "$FIRMWARE_PATH"_entropy.png)" 2> /dev/null
  fi

  # This test takes a long time and so I have removed it
  # we come back to this topic later on - leave it here for the future
  #print_output "\n[*] Architecture testing with binwalk ... could take a while"
  #binwalk -Y "$FIRMWARE_BIN_PATH"

  export OUTPUT_DIR_binwalk
  OUTPUT_DIR_binwalk=$(basename "$FIRMWARE_PATH")
  OUTPUT_DIR_binwalk="$LOG_DIR"/extractor/"$OUTPUT_DIR_binwalk"_binwalk_emba

  echo
  print_output "[*] Extracting firmware to directory $OUTPUT_DIR_binwalk"
  mapfile -t BINWALK_EXTRACT < <(binwalk -e -M -C "$OUTPUT_DIR_binwalk" "$FIRMWARE_PATH")
  if [[ ${#BINWALK_EXTRACT[@]} -ne 0 ]] ; then
    for LINE in "${BINWALK_EXTRACT[@]}" ; do
      print_output "$LINE"
    done
  fi
}
