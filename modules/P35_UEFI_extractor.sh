#!/bin/bash -p

# EMBA - EMBEDDED LINUX ANALYZER
#
# Copyright 2020-2023 Siemens Energy AG
#
# EMBA comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# EMBA is licensed under GPLv3
#
# Author(s): Michael Messner
# Credits:   Binarly for support

# Description: Extracts UEFI images with BIOSUtilities - https://github.com/platomav/BIOSUtilities/tree/refactor
# Pre-checker threading mode - if set to 1, these modules will run in threaded mode
export PRE_THREAD_ENA=0

P35_UEFI_extractor() {
  local NEG_LOG=0

  if [[ "${UEFI_DETECTED}" -eq 1 ]]; then
    module_log_init "${FUNCNAME[0]}"
    module_title "UEFI extractor"
    pre_module_reporter "${FUNCNAME[0]}"
    export FILES_UEFI=0

    EXTRACTION_DIR="${LOG_DIR}"/firmware/uefi_extraction

    uefi_extractor "${FIRMWARE_PATH}" "${EXTRACTION_DIR}"

    if [[ "${FILES_UEFI}" -gt 0 ]]; then
      MD5_DONE_DEEP+=( "$(md5sum "${FIRMWARE_PATH}" | awk '{print $1}')" )
      export FIRMWARE_PATH="${LOG_DIR}"/firmware/
      NEG_LOG=1
    fi

    module_end_log "${FUNCNAME[0]}" "${NEG_LOG}"
  fi
}

uefi_extractor(){
  sub_module_title "UEFI Extractor"

  local FIRMWARE_PATH_="${1:-}"
  local EXTRACTION_DIR_="${2:-}"

  local FIRMWARE_NAME_=""
  local UEFI_EXTRACT_REPORT_FILE=""

  local UEFI_EXTRACT_BIN="${EXT_DIR}""/UEFITool/UEFIExtract"
  local DIRS_UEFI=0
  local NVARS=0
  local PE32_IMAGE=0
  export EFI_ARCH=""

  if ! [[ -f "${FIRMWARE_PATH_}" ]]; then
    print_output "[-] No file for extraction provided"
    return
  fi

  FIRMWARE_NAME_="$(basename "${FIRMWARE_PATH_}")"
  if ! [[ -d "${EXTRACTION_DIR_}" ]]; then
    mkdir -p "${EXTRACTION_DIR_}"
  fi
  cp "${FIRMWARE_PATH_}" "${EXTRACTION_DIR_}"
  "${UEFI_EXTRACT_BIN}" "${EXTRACTION_DIR_}"/firmware all &> "${LOG_PATH_MODULE}"/uefi_extractor_"${FIRMWARE_NAME_}".log

  UEFI_EXTRACT_REPORT_FILE="${EXTRACTION_DIR_}"/firmware.report.txt
  mv "${UEFI_EXTRACT_REPORT_FILE}" "${LOG_PATH_MODULE}"
  UEFI_EXTRACT_REPORT_FILE="${LOG_PATH_MODULE}"/firmware.report.txt
  if [[ -f "${EXTRACTION_DIR_}"/firmware ]]; then
    rm "${EXTRACTION_DIR_}"/firmware
  fi

  if [[ -f "${LOG_PATH_MODULE}"/uefi_extractor_"${FIRMWARE_NAME_}".log ]]; then
    tee -a "${LOG_FILE}" < "${LOG_PATH_MODULE}"/uefi_extractor_"${FIRMWARE_NAME_}".log
  fi

  print_ln
  print_output "[*] Using the following firmware directory (${ORANGE}${EXTRACTION_DIR_}/firmware.dump${NC}) as base directory:"
  find "${EXTRACTION_DIR_}"/firmware.dump -xdev -maxdepth 1 -ls | tee -a "${LOG_FILE}"
  print_ln

  NVARS=$(grep -c "NVAR entry" "${UEFI_EXTRACT_REPORT_FILE}" || true)
  PE32_IMAGE=$(grep -c "PE32 image" "${UEFI_EXTRACT_REPORT_FILE}" || true)
  DRIVER_COUNT=$(grep -c "DXE driver" "${UEFI_EXTRACT_REPORT_FILE}" || true)
  EFI_ARCH=$(find "${EXTRACTION_DIR_}" -name 'info.txt' -exec grep 'Machine type:' {} \; | sed -E 's/Machine\ type\:\ //g' | uniq | head -n 1)
  FILES_UEFI=$(grep -c "File" "${UEFI_EXTRACT_REPORT_FILE}" || true)
  DIRS_UEFI=$(find "${EXTRACTION_DIR_}" -type d | wc -l)

  # do a second round with unblob
  unblobber "${FIRMWARE_PATH_}" "${EXTRACTION_DIR_}_unblob_extracted"

  print_output "[*] Extracted ${ORANGE}${FILES_UEFI}${NC} files and ${ORANGE}${DIRS_UEFI}${NC} directories from UEFI firmware image."
  print_output "[*] Found ${ORANGE}${NVARS}${NC} NVARS and ${ORANGE}${DRIVER_COUNT}${NC} drivers."
  if [[ -n "${EFI_ARCH}" ]]; then
    print_output "[*] Found ${ORANGE}${PE32_IMAGE}${NC} PE32 images for architecture ${ORANGE}${EFI_ARCH}${NC} drivers."
    print_output "[+] Possible architecture details found (${ORANGE}UEFI Extractor${GREEN}): ${ORANGE}${EFI_ARCH}${NC}"
    backup_var "EFI_ARCH" "${EFI_ARCH}"
    if [[ "${FILES_UEFI}" -gt 0 ]] && [[ "${DIRS_UEFI}" -gt 0 ]]; then
      # with VERIFIED_UEFI=1 we do not run deep-extraction
      export VERIFIED_UEFI=1
    fi
  fi
  print_ln

  if [[ -d "${EXTRACTION_DIR_}_unblob_extracted" ]]; then
    FILES_UEFI_UNBLOB=$(find "${EXTRACTION_DIR_}_unblob_extracted" -type f | wc -l)
    DIRS_UEFI_UNBLOB=$(find "${EXTRACTION_DIR_}_unblob_extracted" -type d | wc -l)
    print_output "[*] Extracted ${ORANGE}${FILES_UEFI_UNBLOB}${NC} files and ${ORANGE}${DIRS_UEFI_UNBLOB}${NC} directories from UEFI firmware image (with unblob)."
  fi
  print_ln

  write_csv_log "Extractor module" "Original file" "extracted file/dir" "file counter" "directory counter" "UEFI architecture"
  write_csv_log "UEFI extractor" "${FIRMWARE_PATH_}" "${EXTRACTION_DIR_}" "${FILES_UEFI}" "${DIRS_UEFI}" "${EFI_ARCH}"
}
