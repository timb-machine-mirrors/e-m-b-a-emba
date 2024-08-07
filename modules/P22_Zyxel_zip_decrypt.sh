#!/bin/bash

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

# Description:  Extracts Zyxel firmware images that are protected with a password
#               Further information can be found in this paper:
#               https://media.defcon.org/DEF%20CON%2030/DEF%20CON%2030%20presentations/Jay%20Lagorio%20-%20Tear%20Down%20this%20Zywall%20Breaking%20Open%20Zyxel%20Encrypted%20Firmware.pdf
#               Thanks to https://twitter.com/jaylagorio

# Pre-checker threading mode - if set to 1, these modules will run in threaded mode
export PRE_THREAD_ENA=0

P22_Zyxel_zip_decrypt() {
  local lNEG_LOG=0

  if [[ "${ZYXEL_ZIP}" -eq 1 ]]; then
    module_log_init "${FUNCNAME[0]}"
    module_title "Zyxel protected ZIP firmware extractor"
    pre_module_reporter "${FUNCNAME[0]}"

    lEXTRACTION_DIR="${LOG_DIR}"/firmware/firmware_zyxel_zip

    zyxel_zip_extractor "${FIRMWARE_PATH}" "${lEXTRACTION_DIR}"

    lNEG_LOG=1
    module_end_log "${FUNCNAME[0]}" "${lNEG_LOG}"
  fi
}

zyxel_zip_extractor() {
  local lRI_FILE_="${1:-}"
  local lEXTRACTION_DIR_="${2:-}"

  local lRI_FILE_BIN=""
  local lZLD_DIR=""
  local lRI_FILE_BIN_PATH=""
  local lZLD_BINS_ARR=()
  local lZLD_BIN=""
  local lCOMPRESS_IMG=""

  sub_module_title "Zyxel protected ZIP firmware extractor"

  if ! [[ -f "${lRI_FILE_}" ]]; then
    print_output "[-] Zyxel - No file for extraction provided"
    return
  fi
  if ! [[ "${lRI_FILE_}" =~ .*\.ri ]]; then
    print_output "[-] Zyxel - No valid ri file for extraction provided"
    return
  fi

  unblobber "${lRI_FILE_}" "${lEXTRACTION_DIR_}"
  print_ln

  if command -v jchroot > /dev/null; then
    local lCHROOT="jchroot"
    # OPTS see https://github.com/vincentbernat/jchroot#security-note
    local lOPTS=(-n emba -U -u 0 -g 0 -M "0 $(id -u) 1" -G "0 $(id -g) 1")
    print_output "[*] Using ${ORANGE}jchroot${NC} for building more secure chroot environments"
  else
    print_output "[-] No jchroot binary found ..."
    return
  fi

  mapfile -t lZLD_BINS_ARR < <(find "${lEXTRACTION_DIR_}" -name "zld_fsextract")
  lRI_FILE_BIN="$(basename -s .ri "${lRI_FILE_}")".bin

  for lZLD_BIN in "${lZLD_BINS_ARR[@]}"; do
    local lFILES_ZYXEL=0
    local lDIRS_ZYXEL=0
    local lZIP_KEY=""
    print_output "[*] Checking ${ORANGE}${lZLD_BIN}${NC}"

    lZLD_DIR=$(dirname "${lZLD_BIN}")
    lRI_FILE_BIN_PATH=$(find "${LOG_DIR}"/firmware -name "${lRI_FILE_BIN}" | head -1)
    # => this should be the protected Zip file

    if [[ $(file "${lZLD_BIN}") == *"ELF"* ]] && [[ $(file "${lRI_FILE_BIN_PATH}") == *"Zip archive data"* ]]; then
      print_output "[*] Found Zyxel environment in ${ORANGE}${lZLD_DIR}${NC}"
      # now we know that we have an elf for extraction and and unzip binary in the extraction dir
      # this is everything we need for the key
      if ( file "${lZLD_BIN}" | grep -q "ELF 32-bit MSB executable, MIPS, N32 MIPS64 rel2 version 1" ) ; then
        # todo: check if Zyxel also uses other architectures
        local lEMULATOR="qemu-mipsn32-static"
        print_output "[*] Found valid emulator ${ORANGE}${lEMULATOR}${NC}"
      else
        print_output "[-] WARNING: Unsupported architecture for key identification:"
        print_output "$(indent "$(file "${lZLD_BIN}")")"
        print_output "[-] Please open an issue at https://github.com/e-m-b-a/emba/issues"
        continue
      fi

      print_output "[*] Running Zyxel emulation for key extraction ..."

      if ! [[ -e "$(command -v "${lEMULATOR}")" ]]; then
        print_output "[-] No valid emulator (${ORANGE}${lEMULATOR}${NC}) found in your environment"
        return
      fi

      cp "$(command -v "${lEMULATOR}")" "${lZLD_DIR}" || ( print_output "[-] Something went wrong" && return)
      cp "${lRI_FILE_BIN_PATH}" "${lZLD_DIR}" || ( print_output "[-] Something went wrong" && return)
      lZLD_BIN=$(basename "${lZLD_BIN}")

      chmod +x "${lZLD_DIR}"/"${lZLD_BIN}"
      timeout --preserve-status --signal SIGINT 2s "${lCHROOT}" "${lOPTS[@]}" "${lZLD_DIR}" -- ./"${lEMULATOR}" -strace ./"${lZLD_BIN}" "${lRI_FILE_BIN}" AABBCCDD >> "${LOG_PATH_MODULE}"/zld_strace.log 2>&1 || true
      rm "${lZLD_DIR}"/"${lEMULATOR}" || true

      if [[ -f "${LOG_PATH_MODULE}"/zld_strace.log ]] && [[ -s "${LOG_PATH_MODULE}"/zld_strace.log ]]; then
        lZIP_KEY=$(grep -a -E "^[0-9]+\ execve.*AABBCCDD\",\"-o" "${LOG_PATH_MODULE}"/zld_strace.log| cut -d, -f6 | sort -u | sed 's/^\"//' | sed 's/\"$//')
      else
        print_output "[-] No qemu strace log generated -> no further processing possible"
      fi

      # if we have found a lZIP_KEY:
      if [[ -v lZIP_KEY ]]; then
        print_ln
        print_output "[+] Possible ZIP key detected: ${ORANGE}${lZIP_KEY}${NC}" "" "${LOG_PATH_MODULE}/zld_strace.log"

        7z x -p"${lZIP_KEY}" -o"${lEXTRACTION_DIR_}"/firmware_zyxel_extracted "${lRI_FILE_BIN_PATH}" || true

        lFILES_ZYXEL=$(find "${lEXTRACTION_DIR_}"/firmware_zyxel_extracted -type f | wc -l)
        lDIRS_ZYXEL=$(find "${lEXTRACTION_DIR_}"/firmware_zyxel_extracted -type d | wc -l)

        print_ln
        print_output "[*] Zyxel 1st stage - Extracted ${ORANGE}${lFILES_ZYXEL}${NC} files and ${ORANGE}${lDIRS_ZYXEL}${NC} directories from the firmware image."
        write_csv_log "Extractor module" "Original file" "extracted file/dir" "file counter" "directory counter" "further details"
        write_csv_log "Zyxel extractor" "${lRI_FILE_BIN_PATH}" "${lEXTRACTION_DIR_}/firmware_zyxel_extracted" "${lFILES_ZYXEL}" "${lDIRS_ZYXEL}" "NA"
      else
        print_output "[-] No ZIP key detected -> no further processing possible"
      fi

      # if it was possible to extract something with the key:
      if [[ "${lFILES_ZYXEL}" -gt 0 ]]; then
        # compress.img ist the firmware -> letz search for it
        lCOMPRESS_IMG=$(find "${lEXTRACTION_DIR_}"/firmware_zyxel_extracted -type f -name compress.img | sort -u)
        if [[ $(file "${lCOMPRESS_IMG}") == *"Squashfs"* ]]; then
          print_output "[+] Found valid ${ORANGE}compress.img${GREEN} and extract it now"
          unblobber "${lCOMPRESS_IMG}" "${lEXTRACTION_DIR_}/firmware_zyxel_extracted/compress_img_extracted"
          lFILES_ZYXEL=$(find "${lEXTRACTION_DIR_}"/firmware_zyxel_extracted/compress_img_extracted -type f | wc -l)
          lDIRS_ZYXEL=$(find "${lEXTRACTION_DIR_}"/firmware_zyxel_extracted/compress_img_extracted -type d | wc -l)
          print_output "[*] Zyxel 2nd stage - Extracted ${ORANGE}${lFILES_ZYXEL}${NC} files and ${ORANGE}${lDIRS_ZYXEL}${NC} directories from the firmware image."
          write_csv_log "Zyxel extractor" "${lRI_FILE_BIN_PATH}" "${lEXTRACTION_DIR_}/firmware_zyxel_extracted/compress_img_extracted" "${lFILES_ZYXEL}" "${lDIRS_ZYXEL}" "NA"
          export FIRMWARE_PATH="${LOG_DIR}"/firmware/
          backup_var "FIRMWARE_PATH" "${FIRMWARE_PATH}"
          print_ln
          break
        else
          print_output "[-] No valid ${ORANGE}compress.img${NC} file found"
        fi
      else
        print_output "[-] 1st stage Zip extraction failed"
      fi
      print_ln
    else
      print_output "[-] No environment for Zyxel decryption found"
    fi
  done
}
