#!/bin/bash -p

# EMBA - EMBEDDED LINUX ANALYZER
#
# Copyright 2020-2024 Siemens Energy AG
#
# EMBA comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# EMBA is licensed under GPLv3
# SPDX-License-Identifier: GPL-3.0-only
#
# Author(s): Michael Messner

# Description: Extracts vmdk images
# Pre-checker threading mode - if set to 1, these modules will run in threaded mode
export PRE_THREAD_ENA=0

P10_vmdk_extractor() {
  local lNEG_LOG=0

  if [[ "${VMDK_DETECTED-0}" -eq 1 ]]; then
    module_log_init "${FUNCNAME[0]}"
    module_title "VMDK (Virtual Machine Disk) extractor"
    pre_module_reporter "${FUNCNAME[0]}"
    EXTRACTION_DIR="${LOG_DIR}"/firmware/vmdk_extractor/

    vmdk_extractor "${FIRMWARE_PATH}" "${EXTRACTION_DIR}"

    if [[ "${VMDK_FILES}" -gt 0 ]]; then
      export FIRMWARE_PATH="${LOG_DIR}"/firmware/
      backup_var "FIRMWARE_PATH" "${FIRMWARE_PATH}"
    fi
    lNEG_LOG=1
    module_end_log "${FUNCNAME[0]}" "${lNEG_LOG}"
  fi
}

vmdk_extractor() {
  local lVMDK_PATH_="${1:-}"
  local lEXTRACTION_DIR_="${2:-}"
  local lMOUNT_DEV=""
  local lDEV_NAME=""
  local lTMP_VMDK_MNT="${TMP_DIR}/vmdk_mount_${RANDOM}"
  local lVMDK_DIRS=0
  local lRET=0
  export VMDK_FILES=0
  local lVMDK_VIRT_FS_ARR=()

  if ! [[ -f "${lVMDK_PATH_}" ]]; then
    print_output "[-] No file for extraction provided"
    return
  fi

  sub_module_title "VMDK (Virtual Machine Disk) extractor"

  print_output "[*] Enumeration of devices in VMDK images ${ORANGE}${lVMDK_PATH_}${NC}"
  disable_strict_mode "${STRICT_MODE}" 0
  virt-filesystems -a "${lVMDK_PATH_}" > "${TMP_DIR}"/vmdk.log
  lRET="$?"

  if [[ "${lRET}" -ne 0 ]]; then
    # backup with 7z
    7z x -o"${lEXTRACTION_DIR_}" "${lVMDK_PATH_}"
    lRET="$?"
    if [[ "${lRET}" -ne 0 ]]; then
      print_output "[-] WARNING: VMDK filesystem not enumerated"
      enable_strict_mode "${STRICT_MODE}" 0
      return
    fi
  else
    mapfile -t lVMDK_VIRT_FS_ARR < "${TMP_DIR}"/vmdk.log
    for lMOUNT_DEV in "${lVMDK_VIRT_FS_ARR[@]}"; do
      print_output "[*] Found device ${ORANGE}${lMOUNT_DEV}${NC}"
    done
  fi
  enable_strict_mode "${STRICT_MODE}" 0

  mkdir -p "${lTMP_VMDK_MNT}" || true

  for lMOUNT_DEV in "${lVMDK_VIRT_FS_ARR[@]}"; do
    lDEV_NAME=$(basename "${lMOUNT_DEV}")
    print_output "[*] Trying to mount ${ORANGE}${lMOUNT_DEV}${NC} to ${ORANGE}${lTMP_VMDK_MNT}${NC} directory"
    # if troubles ahead with vmdk mount, remove the error redirection
    guestmount -a "${lVMDK_PATH_}" -m "${lMOUNT_DEV}" --ro "${lTMP_VMDK_MNT}" 2>/dev/null || true
    if mount | grep -q vmdk_mount; then
      print_output "[*] Copying ${ORANGE}${lMOUNT_DEV}${NC} to firmware directory ${ORANGE}${lEXTRACTION_DIR_}/${lDEV_NAME}${NC}"
      mkdir -p "${lEXTRACTION_DIR_}"/"${lDEV_NAME}"/ || true
      cp -pr "${lTMP_VMDK_MNT}"/* "${lEXTRACTION_DIR_}"/"${lDEV_NAME}"/ || true
      umount "${lTMP_VMDK_MNT}"
    fi
  done

  if [[ -d "${lEXTRACTION_DIR_}" ]]; then
    VMDK_FILES=$(find "${lEXTRACTION_DIR_}" -type f | wc -l)
    lVMDK_DIRS=$(find "${lEXTRACTION_DIR_}" -type d | wc -l)
  fi

  if [[ "${VMDK_FILES}" -gt 0 ]]; then
    print_ln
    print_output "[*] Extracted ${ORANGE}${VMDK_FILES}${NC} files and ${ORANGE}${lVMDK_DIRS}${NC} directories from the firmware image."
    write_csv_log "Extractor module" "Original file" "extracted file/dir" "file counter" "directory counter" "further details"
    write_csv_log "VMDK extractor" "${lVMDK_PATH_}" "${lEXTRACTION_DIR_}" "${VMDK_FILES}" "${lVMDK_DIRS}" "NA"
    # currently unblob has issues with VMDKs. We need to disable it for this extraction process
    safe_echo 0 > "${TMP_DIR}"/unblob_disable.cfg
  fi
  rm -r "${lTMP_VMDK_MNT}" || true
}
