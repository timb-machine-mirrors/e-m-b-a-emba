#!/bin/bash -p

# EMBA - EMBEDDED LINUX ANALYZER
#
# Copyright 2020-2024 Siemens Energy AG
# Copyright 2020-2023 Siemens AG
#
# EMBA comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# EMBA is licensed under GPLv3
# SPDX-License-Identifier: GPL-3.0-only
#
# Author(s): Michael Messner, Pascal Eckmann

# Description:  Iterates through a list with regex identifiers of version details
#               (e.g. busybox:binary:"BusyBox\ v[0-9]\.[0-9][0-9]\.[0-9]\ .*\ multi-call\ binary" ) of all executables and
#               checks if these fit on a binary in the firmware.
#               The version configuration file is stored in config/bin_version_strings.cfg

# Threading priority - if set to 1, these modules will be executed first
export THREAD_PRIO=1

S09_firmware_base_version_check() {

  # this module check for version details statically.
  # this module is designed for *x based systems

  module_log_init "${FUNCNAME[0]}"
  module_title "Static binary firmware versions detection"
  pre_module_reporter "${FUNCNAME[0]}"

  local lEXTRACTOR_LOG="${LOG_DIR}"/p55_unblob_extractor/unblob_firmware.log

  print_output "[*] Static version detection running ..." "no_log" | tr -d "\n"
  write_csv_log "binary/file" "version_rule" "version_detected" "csv_rule" "license" "static/emulation"

  export TYPE="static"
  export VERSION_IDENTIFIER=""
  export WAIT_PIDS_S09=()
  export WAIT_PIDS_S09_1=()
  local lVERSIONS_DETECTED=""
  local lVERSION_IDENTIFIER_CFG="${CONFIG_DIR}"/bin_version_strings.cfg

  local lFILE_ARR_TMP=()
  local lFILE=""
  local lBIN=""
  local lBIN_FILE=""

  # set default confidence level
  # 1 -> very-low
  # 2 -> low
  # 3 -> medium
  # 4 -> high
  local lCONFIDENCE_LEVEL=3

  if [[ "${QUICK_SCAN:-0}" -eq 1 ]] && [[ -f "${CONFIG_DIR}"/bin_version_strings_quick.cfg ]]; then
    # the quick scan configuration has only entries that have known vulnerabilities in the CVE database
    local lVERSION_IDENTIFIER_CFG="${CONFIG_DIR}"/bin_version_strings_quick.cfg
    local lV_CNT=0
    lV_CNT=$(wc -l "${CONFIG_DIR}"/bin_version_strings_quick.cfg)
    print_output "[*] Quick scan enabled - ${lV_CNT/\ *} version identifiers loaded"
  fi

  # in sbom mode we probably have not populated our arrays
  if [[ "${SBOM_MINIMAL:-0}" -eq 1 ]] || [[ "${#FILE_ARR[@]}" -eq 0 ]]; then
    prepare_file_arr_limited "${LOG_DIR}/firmware"
    # print_output "[*] Prepare file array ..." "no_log"
    # readarray -t FILE_ARR < <(find "${LOG_DIR}/firmware" -xdev "${EXCL_FIND[@]}" -type f -exec md5sum {} \; 2>/dev/null | sort -u -k1,1 | cut -d\  -f3- )
    FILE_ARR=( "${FILE_ARR_LIMITED[@]}" )
  fi

  printf "%s\n" "${FILE_ARR[@]}" > "${LOG_PATH_MODULE}"/firmware_binaries.txt

  if [[ "${SBOM_MINIMAL:-0}" -eq 1 ]]; then
    print_output "[*] Checking for common package manager environments to optimize static version detection"
    # Debian:
    find "${LOG_DIR}"/firmware -path "*dpkg/info/*.list" -type f -print0|xargs -r -0 -P 16 -I % sh -c 'cat %' | sort -u > "${LOG_PATH_MODULE}"/debian_known_files.txt || true
    # OpenWRT
    find "${LOG_DIR}"/firmware -path "*opkg/info/*.list" -type f -print0|xargs -r -0 -P 16 -I % sh -c 'cat %' | sort -u > "${LOG_PATH_MODULE}"/openwrt_known_files.txt || true
    # Todo: rpm
    # lRPM_DIR=$(find "${LOG_DIR}"/firmware -xdev -path "*rpm/Package" -type f -exec dirname {} \; | sort -u || true)
    # lRPM_DIR=$(find "${LOG_DIR}"/firmware -xdev -path "*rpm/rpmdb.sqlite" -type f -exec dirname {} \; | sort -u || true)
    # get all packages in array and run through them to extract all paths
    # rpm -ql --dbpath "${lRPM_DIR}" "${lPACKAGE_AND_VERSION}"

    if [[ -f "${LOG_PATH_MODULE}"/debian_known_files.txt ]]; then
      cat "${LOG_PATH_MODULE}"/debian_known_files.txt >> "${LOG_PATH_MODULE}"/pkg_known_files.txt
    fi
    if [[ -f "${LOG_PATH_MODULE}"/openwrt_known_files.txt ]]; then
      cat "${LOG_PATH_MODULE}"/openwrt_known_files.txt >> "${LOG_PATH_MODULE}"/pkg_known_files.txt
    fi
    if [[ -f "${LOG_PATH_MODULE}"/rpm_known_files.txt ]]; then
      cat "${LOG_PATH_MODULE}"/rpm_known_files.txt >> "${LOG_PATH_MODULE}"/pkg_known_files.txt
    fi

    if [[ -f "${LOG_PATH_MODULE}"/pkg_known_files.txt ]]; then
      sed -i '/\[/d' "${LOG_PATH_MODULE}"/pkg_known_files.txt || true
      sed -i '/\/\.$/d' "${LOG_PATH_MODULE}"/pkg_known_files.txt || true
      mapfile -t lFILE_ARR_PKG < "${LOG_PATH_MODULE}"/pkg_known_files.txt
    fi

    if [[ "${#lFILE_ARR_PKG[@]}" -gt 10 ]]; then
      print_output "[*] Found package manager with ${ORANGE}${#lFILE_ARR_PKG[@]}${NC} package files - testing against file array ${ORANGE}${#FILE_ARR[@]}${NC}"
      for lPKG_FILE in "${lFILE_ARR_PKG[@]}"; do
        (grep -E "${lPKG_FILE}$" "${LOG_PATH_MODULE}/firmware_binaries.txt" >> "${LOG_PATH_MODULE}"/known_system_pkg_files.txt || true)&
      done

      print_output "[*] Waiting for grepping jobs" "no_log"
      # shellcheck disable=SC2046
      wait $(jobs -p)

      sort -u "${LOG_PATH_MODULE}"/known_system_pkg_files.txt >> "${LOG_PATH_MODULE}"/known_system_pkg_files_sorted.txt || true
      sort -u "${LOG_PATH_MODULE}"/firmware_binaries.txt >> "${LOG_PATH_MODULE}"/firmware_binaries_sorted.txt || true

      # we have now all our filesystem bins in "${LOG_PATH_MODULE}/firmware_binaries.txt"
      # we have the matching filesystem bin in "${LOG_PATH_MODULE}"/known_system_files.txt
      # now we just need to do a diff on them and we should have only the non matching files
      comm -23 "${LOG_PATH_MODULE}/firmware_binaries_sorted.txt" "${LOG_PATH_MODULE}"/known_system_pkg_files_sorted.txt > "${LOG_PATH_MODULE}"/known_system_files_diffed.txt || true
      mapfile -t lFILE_ARR_TMP < "${LOG_PATH_MODULE}"/known_system_files_diffed.txt

      if [[ "${#lFILE_ARR_TMP[@]}" -lt "${#FILE_ARR[@]}" ]]; then
        print_output "[*] Identified ${ORANGE}${#FILE_ARR[@]}${NC} binaries before package manager matching"
        print_output "[*] EMBA is testing ${ORANGE}${#lFILE_ARR_TMP[@]}${NC} files which are not handled by the package manager"
        FILE_ARR=()
        for lFILE in "${lFILE_ARR_TMP[@]}"; do
          if file -b "${lFILE}"| grep -q -v "text"; then
            # print_output "$(indent "$(orange "${lFILE}")")"
            FILE_ARR+=( "${lFILE}" )
            echo "${lFILE}" >> "${LOG_PATH_MODULE}"/final_bins.txt
          fi
        done
        print_output "[*] EMBA is testing ${ORANGE}${#FILE_ARR[@]}${NC} binaries which are not handled by the package manager"
      else
        print_output "[*] No package manager updates for static analysis"
      fi
    fi
  fi

  print_output "[*] Generate strings overview for static version analysis ..."
  mkdir "${LOG_PATH_MODULE}"/strings_bins/
  if ! [[ -d "${LOG_PATH_MODULE}"/strings_bins ]]; then
    mkdir "${LOG_PATH_MODULE}"/strings_bins || true
  fi
  for lBIN in "${FILE_ARR[@]}"; do
    generate_strings "${lBIN}" &
    local lTMP_PID="$!"
    store_kill_pids "${lTMP_PID}"
    WAIT_PIDS_S09_1+=( "${lTMP_PID}" )
    max_pids_protection "${MAX_MOD_THREADS}" "${WAIT_PIDS_S09_1[@]}"
  done

  print_output "[*] Waiting for strings generator" "no_log"
  wait_for_pid "${WAIT_PIDS_S09_1[@]}"
  print_output "[*] Proceeding with version detection for ${ORANGE}${#FILE_ARR[@]}${NC} binary files"

  while read -r VERSION_LINE; do
    print_dot

    local lSTRICT=""
    export LIC=""
    local lAPP_NAME=""
    local lAPP_VERS=""
    local lAPP_MAINT=""
    local lBIN_PATH=""
    export CSV_REGEX=""
    local lBIN=""

    local lSHA512_CHECKSUM=""
    local lSHA256_CHECKSUM=""
    local lPURL_IDENTIFIER="NA"
    local lPACKAGING_SYSTEM="static_bin_analysis"
    local lVERSION_FINDER=""

    lSTRICT="$(safe_echo "${VERSION_LINE}" | cut -d\; -f2)"
    LIC="$(safe_echo "${VERSION_LINE}" | cut -d\; -f3)"
    lAPP_NAME="$(safe_echo "${VERSION_LINE}" | cut -d\; -f1)"
    CSV_REGEX="$(echo "${VERSION_LINE}" | cut -d\; -f5)"

    if [[ -f "${S09_CSV_LOG}" ]]; then
      # this should prevent double checking - if a version identifier was already successful we do not need to
      # test the other identifiers. In threaded mode this usually does not decrease testing speed.
      if [[ "$(tail -n +2 "${S09_CSV_LOG}" | cut -d\; -f2 | grep -c "^${lAPP_NAME}$")" -gt 0 ]]; then
        print_output "[*] Already identified component for identifier ${lAPP_NAME} - ${CSV_REGEX} ... skipping further tests" "no_log"
        continue
      fi
    fi

    VERSION_IDENTIFIER="$(safe_echo "${VERSION_LINE}" | cut -d\; -f4)"
    if [[ "${VERSION_IDENTIFIER: 0:1}" == '"' ]]; then
      VERSION_IDENTIFIER="${VERSION_IDENTIFIER/\"}"
      VERSION_IDENTIFIER="${VERSION_IDENTIFIER%\"}"
    fi
    lOS_IDENTIFIED=$(distri_check)

    if [[ "${lSTRICT}" == *"strict"* ]]; then
      local lSTRICT_BINS_ARR=()
      local lBIN_ARCH=""

      # strict mode
      #   use the defined regex only on a binary called lAPP_NAME (field 1)
      #   Warning: strict mode is deprecated and will be removed in the future.

      [[ "${RTOS}" -eq 1 ]] && continue

      mapfile -t lSTRICT_BINS_ARR < <(find "${OUTPUT_DIR}" -xdev -executable -type f -name "${lAPP_NAME}" -print0|xargs -r -0 -P 16 -I % sh -c 'md5sum % 2>/dev/null' | sort -u -k1,1 | cut -d\  -f3)
      # before moving on we need to ensure our strings files are generated:
      [[ "${THREADED}" -eq 1 ]] && wait_for_pid "${WAIT_PIDS_S09_1[@]}"
      for lBIN in "${lSTRICT_BINS_ARR[@]}"; do
        # as the STRICT_BINS array could also include executable scripts we have to check for ELF files now:
        lBIN_FILE=$(file -b "${lBIN}")
        if [[ "${lBIN_FILE}" == *"ELF"* ]] ; then
          MD5_SUM="$(md5sum "${lBIN}" | awk '{print $1}')"
          lAPP_NAME="$(basename "${lBIN}")"
          local lSTRINGS_OUTPUT="${LOG_PATH_MODULE}"/strings_bins/strings_"${MD5_SUM}"_"${lAPP_NAME}".txt
          if ! [[ -f "${lSTRINGS_OUTPUT}" ]]; then
            continue
          fi
          lVERSION_FINDER=$(grep -a -E "${VERSION_IDENTIFIER}" "${lSTRINGS_OUTPUT}" | sort -u || true)
          if [[ -n ${lVERSION_FINDER} ]]; then
            print_ln "no_log"
            print_output "[+] Version information found ${RED}${lAPP_NAME} ${lVERSION_FINDER}${NC}${GREEN} in binary ${ORANGE}$(print_path "${lBIN}")${GREEN} (license: ${ORANGE}${LIC}${GREEN}) (${ORANGE}static - strict - deprecated${GREEN})."
            CSV_RULE=$(get_csv_rule "${lVERSION_FINDER}" "${CSV_REGEX}")
            CSV_RULE="${CSV_RULE//\ }"
            write_csv_log "${lBIN}" "${lAPP_NAME}" "${lVERSION_FINDER}" "${CSV_RULE}" "${LIC}" "${TYPE}"
            check_for_s08_csv_log "${S08_CSV_LOG}"

            lSHA256_CHECKSUM="$(sha256sum "${lBIN}" | awk '{print $1}')"
            lSHA512_CHECKSUM="$(sha512sum "${lBIN}" | awk '{print $1}')"
            lCPE_IDENTIFIER=$(build_cpe_identifier "${CSV_RULE}")
            lBIN_ARCH=$(echo "${lBIN_FILE}" | cut -d ',' -f2)
            lBIN_ARCH=${lBIN_ARCH#\ }
            lPURL_IDENTIFIER=$(build_generic_purl "${CSV_RULE}" "${lOS_IDENTIFIED}" "${lBIN_ARCH}")

            lAPP_MAINT=$(echo "${CSV_RULE}" | cut -d ':' -f2)
            lAPP_NAME=$(echo "${CSV_RULE}" | cut -d ':' -f3)
            lAPP_VERS=$(echo "${CSV_RULE}" | cut -d ':' -f4-5)

            # add source file path information to our properties array:
            local lPROP_ARRAY_INIT_ARR=()
            lPROP_ARRAY_INIT_ARR+=( "source_path:${lBIN}" )
            lPROP_ARRAY_INIT_ARR+=( "source_arch:${lBIN_ARCH}" )
            lPROP_ARRAY_INIT_ARR+=( "source_details:${lBIN_FILE}" )
            lPROP_ARRAY_INIT_ARR+=( "identifer_detected:${lVERSION_FINDER}" )
            lPROP_ARRAY_INIT_ARR+=( "minimal_identifier:${CSV_RULE}" )
            lPROP_ARRAY_INIT_ARR+=( "confidence:$(get_confidence_string ${lCONFIDENCE_LEVEL})" )

            build_sbom_json_properties_arr "${lPROP_ARRAY_INIT_ARR[@]}"

            # build_json_hashes_arr sets lHASHES_ARR globally and we unset it afterwards
            # final array with all hash values
            if ! build_sbom_json_hashes_arr "${lBIN}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lPACKAGING_SYSTEM:-NA}" "${lCONFIDENCE_LEVEL}"; then
              print_output "[*] Already found results for ${lAPP_NAME} / ${lAPP_VERS}" "no_log"
              continue
            fi

            # create component entry - this allows adding entries very flexible:
            build_sbom_json_component_arr "${lPACKAGING_SYSTEM}" "${lAPP_TYPE:-library}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lAPP_MAINT:-NA}" "${LIC:-NA}" "${lCPE_IDENTIFIER:-NA}" "${lPURL_IDENTIFIER:-NA}" "${lAPP_DESC:-NA}"

            write_log "${lPACKAGING_SYSTEM};${lBIN:-NA};${MD5_SUM:-NA}/${lSHA256_CHECKSUM:-NA}/${lSHA512_CHECKSUM:-NA};${lAPP_NAME,,};${lVERSION_FINDER:-NA};${CSV_RULE:-NA};${LIC:-NA};maintainer unknown;${lBIN_ARCH:-NA};${lCPE_IDENTIFIER};${lPURL_IDENTIFIER};${SBOM_COMP_BOM_REF:-NA};DESC" "${S08_CSV_LOG}"
            continue
          fi
        fi
      done
      print_dot

    elif [[ "${lSTRICT}" == "zgrep" ]]; then
      local lSPECIAL_FINDS_ARR=()
      local lSFILE=""

      # zgrep mode:
      #   search for files with identifier in field 1
      #   use regex (VERSION_IDENTIFIER) via zgrep on these files
      #   use csv-regex to get the csv-search string for csv lookup

      mapfile -t lSPECIAL_FINDS_ARR < <(find "${FIRMWARE_PATH}" -xdev -type f -name "${lAPP_NAME}" -print0|xargs -r -0 -P 16 -I % sh -c 'zgrep -H '"${VERSION_IDENTIFIER}"' %' || true)
      for lSFILE in "${lSPECIAL_FINDS_ARR[@]}"; do
        lBIN_PATH=$(safe_echo "${lSFILE}" | cut -d ":" -f1)
        lAPP_NAME="$(basename "$(safe_echo "${lSFILE}" | cut -d ":" -f1)")"
        # CSV_REGEX=$(echo "${VERSION_LINE}" | cut -d\; -f5 | sed s/^\"// | sed s/\"$//)
        CSV_REGEX="$(echo "${VERSION_LINE}" | cut -d\; -f5)"
        CSV_REGEX="${CSV_REGEX/\"}"
        CSV_REGEX="${CSV_REGEX%\"}"
        lVERSION_FINDER=$(safe_echo "${lSFILE}" | cut -d ":" -f2-3 | tr -dc '[:print:]')
        CSV_RULE=$(get_csv_rule "${lVERSION_FINDER}" "${CSV_REGEX}")
        CSV_RULE="${CSV_RULE//\ }"

        print_output "[+] Version information found ${RED}""${lVERSION_FINDER}""${NC}${GREEN} in binary ${ORANGE}$(print_path "${lBIN_PATH}")${GREEN} (license: ${ORANGE}${LIC}${GREEN}) (${ORANGE}static - zgrep${GREEN})."
        write_csv_log "${lBIN_PATH}" "${lAPP_NAME}" "${lVERSION_FINDER}" "${CSV_RULE}" "${LIC}" "${TYPE}"
        check_for_s08_csv_log "${S08_CSV_LOG}"

        lMD5_CHECKSUM="$(md5sum "${lBIN_PATH}" | awk '{print $1}')"
        lSHA256_CHECKSUM="$(sha256sum "${lBIN_PATH}" | awk '{print $1}')"
        lSHA512_CHECKSUM="$(sha512sum "${lBIN_PATH}" | awk '{print $1}')"
        lBIN_FILE=$(file -b "${lBIN}")
        lBIN_ARCH=$(echo "${lBIN_FILE}" | cut -d ',' -f2)
        lBIN_ARCH=${lBIN_ARCH#\ }

        lCPE_IDENTIFIER=$(build_cpe_identifier "${CSV_RULE}")
        lPURL_IDENTIFIER=$(build_generic_purl "${CSV_RULE}" "${lOS_IDENTIFIED}" "${lBIN_ARCH}")

        lAPP_MAINT=$(echo "${CSV_RULE}" | cut -d ':' -f2)
        lAPP_NAME=$(echo "${CSV_RULE}" | cut -d ':' -f3)
        lAPP_VERS=$(echo "${CSV_RULE}" | cut -d ':' -f4-5)

        # add source file path information to our properties array:
        local lPROP_ARRAY_INIT_ARR=()
        lPROP_ARRAY_INIT_ARR+=( "source_path:${lBIN}" )
        lPROP_ARRAY_INIT_ARR+=( "source_arch:${lBIN_ARCH}" )
        lPROP_ARRAY_INIT_ARR+=( "source_details:${lBIN_FILE}" )
        lPROP_ARRAY_INIT_ARR+=( "identifer_detected:${lVERSION_FINDER}" )
        lPROP_ARRAY_INIT_ARR+=( "minimal_identifier:${CSV_RULE}" )
        lPROP_ARRAY_INIT_ARR+=( "confidence:$(get_confidence_string ${lCONFIDENCE_LEVEL})" )

        build_sbom_json_properties_arr "${lPROP_ARRAY_INIT_ARR[@]}"

        # build_json_hashes_arr sets lHASHES_ARR globally and we unset it afterwards
        # final array with all hash values
        if ! build_sbom_json_hashes_arr "${lBIN}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lPACKAGING_SYSTEM:-NA}" "${lCONFIDENCE_LEVEL}"; then
          print_output "[*] Already found results for ${lAPP_NAME} / ${lAPP_VERS}" "no_log"
          continue
        fi

        # create component entry - this allows adding entries very flexible:
        build_sbom_json_component_arr "${lPACKAGING_SYSTEM}" "${lAPP_TYPE:-library}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lAPP_MAINT:-NA}" "${LIC:-NA}" "${lCPE_IDENTIFIER:-NA}" "${lPURL_IDENTIFIER:-NA}" "${lAPP_DESC:-NA}"

        write_log "static_bin_analysis;${lBIN_PATH:-NA};${lMD5_CHECKSUM:-NA}/${lSHA256_CHECKSUM:-NA}/${lSHA512_CHECKSUM:-NA};${lAPP_NAME};${lVERSION_FINDER:-NA};${CSV_RULE};${LIC};maintainer unknown;${lBIN_ARCH};${lCPE_IDENTIFIER};${lPURL_IDENTIFIER};${SBOM_COMP_BOM_REF:-NA};DESC" "${S08_CSV_LOG}"
      done
      print_dot

    else

      # This is default mode!

      if [[ -f "${lEXTRACTOR_LOG}" ]]; then
        # check unblob files sometimes we can find kernel version information or something else in it
        lVERSION_FINDER=$(grep -o -a -E "${VERSION_IDENTIFIER}" "${lEXTRACTOR_LOG}" 2>/dev/null | head -1 2>/dev/null || true)
        if [[ -n ${lVERSION_FINDER} ]]; then
          print_ln "no_log"
          print_output "[+] Version information found ${RED}""${lVERSION_FINDER}""${NC}${GREEN} in unblob logs (license: ${ORANGE}${LIC}${GREEN}) (${ORANGE}static${GREEN})."
          CSV_RULE=$(get_csv_rule "${lVERSION_FINDER}" "${CSV_REGEX}")
          CSV_RULE="${CSV_RULE//\ }"
          write_csv_log "unblob logs" "${lAPP_NAME}" "${lVERSION_FINDER}" "${CSV_RULE}" "${LIC}" "${TYPE}"
          check_for_s08_csv_log "${S08_CSV_LOG}"

          lMD5_CHECKSUM="$(md5sum "${lEXTRACTOR_LOG}" | awk '{print $1}')"
          lSHA256_CHECKSUM="$(sha256sum "${lEXTRACTOR_LOG}" | awk '{print $1}')"
          lSHA512_CHECKSUM="$(sha512sum "${lEXTRACTOR_LOG}" | awk '{print $1}')"
          lCPE_IDENTIFIER=$(build_cpe_identifier "${CSV_RULE}")
          lPURL_IDENTIFIER=$(build_generic_purl "${CSV_RULE}" "${lOS_IDENTIFIED}" "${lBIN_ARCH:-NA}")

          lAPP_MAINT=$(echo "${CSV_RULE}" | cut -d ':' -f2)
          lAPP_NAME=$(echo "${CSV_RULE}" | cut -d ':' -f3)
          lAPP_VERS=$(echo "${CSV_RULE}" | cut -d ':' -f4-5)

          # add source file path information to our properties array:
          local lPROP_ARRAY_INIT_ARR=()
          local lCONFIDENCE_LEVEL=2
          lPROP_ARRAY_INIT_ARR+=( "source_path:${lEXTRACTOR_LOG}" )
          lPROP_ARRAY_INIT_ARR+=( "identifer_detected:${lVERSION_FINDER}" )
          lPROP_ARRAY_INIT_ARR+=( "minimal_identifier:${CSV_RULE}" )
          lPROP_ARRAY_INIT_ARR+=( "confidence:$(get_confidence_string ${lCONFIDENCE_LEVEL})" )

          build_sbom_json_properties_arr "${lPROP_ARRAY_INIT_ARR[@]}"

          # build_json_hashes_arr sets lHASHES_ARR globally and we unset it afterwards
          # final array with all hash values
          if ! build_sbom_json_hashes_arr "${lEXTRACTOR_LOG}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lPACKAGING_SYSTEM:-NA}" "${lCONFIDENCE_LEVEL}"; then
            print_output "[*] Already found results for ${lAPP_NAME} / ${lAPP_VERS}" "no_log"
            continue
          fi

          # create component entry - this allows adding entries very flexible:
          build_sbom_json_component_arr "${lPACKAGING_SYSTEM}" "${lAPP_TYPE:-library}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lAPP_MAINT:-NA}" "${LIC:-NA}" "${lCPE_IDENTIFIER:-NA}" "${lPURL_IDENTIFIER:-NA}" "${lAPP_DESC:-NA}"

          write_log "static_bin_analysis;${lEXTRACTOR_LOG:-NA};${lMD5_CHECKSUM:-NA}/${lSHA256_CHECKSUM:-NA}/${lSHA512_CHECKSUM:-NA};${lAPP_NAME};${lVERSION_FINDER:-NA};${CSV_RULE};${LIC};maintainer unknown;unknown;${lCPE_IDENTIFIER};${lPURL_IDENTIFIER};${SBOM_COMP_BOM_REF:-NA};DESC" "${S08_CSV_LOG}"
          print_dot
        fi
      fi

      print_dot

      if [[ ${FIRMWARE} -eq 0 || -f ${FIRMWARE_PATH} ]]; then
        lVERSION_FINDER=$(find "${FIRMWARE_PATH}" -xdev -type f -print0 2>/dev/null | xargs -0 strings | grep -o -a -E "${VERSION_IDENTIFIER}" | head -1 2>/dev/null || true)

        if [[ -n ${lVERSION_FINDER} ]]; then
          print_ln "no_log"
          print_output "[+] Version information found ${RED}""${lVERSION_FINDER}""${NC}${GREEN} in original firmware file (license: ${ORANGE}${LIC}${GREEN}) (${ORANGE}static${GREEN})."
          CSV_RULE=$(get_csv_rule "${lVERSION_FINDER}" "${CSV_REGEX}")
          CSV_RULE="${CSV_RULE//\ }"
          write_csv_log "firmware" "${lAPP_NAME}" "${lVERSION_FINDER}" "${CSV_RULE}" "${LIC}" "${TYPE}"
          check_for_s08_csv_log "${S08_CSV_LOG}"

          lMD5_CHECKSUM="$(md5sum "${FIRMWARE_PATH}" | awk '{print $1}')"
          lSHA256_CHECKSUM="$(sha256sum "${FIRMWARE_PATH}" | awk '{print $1}')"
          lSHA512_CHECKSUM="$(sha512sum "${FIRMWARE_PATH}" | awk '{print $1}')"
          lBIN_FILE=$(file -b "${FIRMWARE_PATH}")
          lBIN_ARCH=$(echo "${lBIN_FILE}" | cut -d ',' -f2)
          lBIN_ARCH=${lBIN_ARCH#\ }
          lCPE_IDENTIFIER=$(build_cpe_identifier "${CSV_RULE}")
          lPURL_IDENTIFIER=$(build_generic_purl "${CSV_RULE}" "${lOS_IDENTIFIED}" "${lBIN_ARCH}")

          lAPP_MAINT=$(echo "${CSV_RULE}" | cut -d ':' -f2)
          lAPP_NAME=$(echo "${CSV_RULE}" | cut -d ':' -f3)
          lAPP_VERS=$(echo "${CSV_RULE}" | cut -d ':' -f4-5)

          local lCONFIDENCE_LEVEL=2

          # add source file path information to our properties array:
          local lPROP_ARRAY_INIT_ARR=()
          lPROP_ARRAY_INIT_ARR+=( "source_path:${FIRMWARE_PATH}" )
          lPROP_ARRAY_INIT_ARR+=( "source_arch:${lBIN_ARCH}" )
          lPROP_ARRAY_INIT_ARR+=( "source_details:${lBIN_FILE}" )
          lPROP_ARRAY_INIT_ARR+=( "identifer_detected:${lVERSION_FINDER}" )
          lPROP_ARRAY_INIT_ARR+=( "minimal_identifier:${CSV_RULE}" )
          lPROP_ARRAY_INIT_ARR+=( "confidence:$(get_confidence_string ${lCONFIDENCE_LEVEL})" )

          build_sbom_json_properties_arr "${lPROP_ARRAY_INIT_ARR[@]}"

          # build_json_hashes_arr sets lHASHES_ARR globally and we unset it afterwards
          # final array with all hash values
          if ! build_sbom_json_hashes_arr "${FIRMWARE_PATH}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lPACKAGING_SYSTEM:-NA}" "${lCONFIDENCE_LEVEL}"; then
            print_output "[*] Already found results for ${lAPP_NAME} / ${lAPP_VERS}" "no_log"
            continue
          fi

          # create component entry - this allows adding entries very flexible:
          build_sbom_json_component_arr "${lPACKAGING_SYSTEM}" "${lAPP_TYPE:-library}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lAPP_MAINT:-NA}" "${LIC:-NA}" "${lCPE_IDENTIFIER:-NA}" "${lPURL_IDENTIFIER:-NA}" "${lAPP_DESC:-NA}"

          write_log "static_bin_analysis;${FIRMWARE_PATH:-NA};${lMD5_CHECKSUM:-NA}/${lSHA256_CHECKSUM:-NA}/${lSHA512_CHECKSUM:-NA};$(basename "${FIRMWARE_PATH}");${lVERSION_FINDER:-NA};${CSV_RULE};${LIC};maintainer unknown;${lBIN_ARCH:-NA};${lCPE_IDENTIFIER};${lPURL_IDENTIFIER};${SBOM_COMP_BOM_REF:-NA};DESC" "${S08_CSV_LOG}"
        fi
        print_dot
      fi

      if [[ ${RTOS} -eq 1 ]]; then
        # in RTOS mode we also test the original firmware file
        lVERSION_FINDER=$(find "${FIRMWARE_PATH_BAK}" -xdev -type f -print0 2>/dev/null | xargs -0 strings | grep -o -a -E "${VERSION_IDENTIFIER}" | head -1 2>/dev/null || true)
        if [[ -n ${lVERSION_FINDER} ]]; then
          print_ln "no_log"
          print_output "[+] Version information found ${RED}""${lVERSION_FINDER}""${NC}${GREEN} in original firmware file (license: ${ORANGE}${LIC}${GREEN}) (${ORANGE}static${GREEN})."
          CSV_RULE=$(get_csv_rule "${lVERSION_FINDER}" "${CSV_REGEX}")
          write_csv_log "firmware" "${lAPP_NAME}" "${lVERSION_FINDER}" "${CSV_RULE}" "${LIC}" "${TYPE}"
        fi
      fi

      [[ "${THREADED}" -eq 1 ]] && wait_for_pid "${WAIT_PIDS_S09_1[@]}"
      if [[ "${THREADED}" -eq 1 ]]; then
        # this will burn the CPU but in most cases the time of testing is cut into half
        # TODO: change to local vars via parameters - this is ugly as hell!
        bin_string_checker "${lSTRICT}" &
        local lTMP_PID="$!"
        store_kill_pids "${lTMP_PID}"
        WAIT_PIDS_S09+=( "${lTMP_PID}" )
      else
        bin_string_checker "${lSTRICT}"
      fi

      print_dot

    fi

    if [[ "${THREADED}" -eq 1 ]]; then
      if [[ "${#WAIT_PIDS_S09[@]}" -gt "${MAX_MOD_THREADS}" ]]; then
        recover_wait_pids "${WAIT_PIDS_S09[@]}"
        if [[ "${#WAIT_PIDS_S09[@]}" -gt "${MAX_MOD_THREADS}" ]]; then
          max_pids_protection "${MAX_MOD_THREADS}" "${WAIT_PIDS_S09[@]}"
        fi
      fi
    fi

  done < <(grep -v ";no_static;\|;live;" "${lVERSION_IDENTIFIER_CFG}" | grep "^[^#*/;]")

  print_dot

  [[ "${THREADED}" -eq 1 ]] && wait_for_pid "${WAIT_PIDS_S09[@]}"

  lVERSIONS_DETECTED=$(grep -c "Version information found" "${LOG_FILE}" || true)

  module_end_log "${FUNCNAME[0]}" "${lVERSIONS_DETECTED}"
}

check_pkg_files_filesystem() {
  local lPKG_FILE="${1:-}"
  local lFS_FILES="${2:-}"

  # if our file from the filesystem is in the package managers array we do not need to test it here
  if grep -E -q "${lPKG_FILE}$" "${lFS_FILES}"; then
    # print_output "[+] Adding ${ORANGE}${lFILE}${GREEN} to testing array ..." "no_log"
    grep -E "${lPKG_FILE}$" "${lFS_FILES}" >> "${LOG_PATH_MODULE}"/known_system_files.txt
  fi
}

build_generic_purl() {
  local lCSV_RULE="${1:-}"
  local lOS_IDENTIFIED="${2:-NA}"
  local lAPP_ARCH="${3:-}"

  if [[ "${lOS_IDENTIFIED}" == "NA" ]]; then
    lOS_IDENTIFIED="generic"
  fi

  local lBIN_VENDOR=""
  local lBIN_NAME=""
  local lBIN_VERS=""
  local lPURL_IDENTIFIER=""

  lBIN_VENDOR=$(echo "${lCSV_RULE}" | cut -d ':' -f2)
  lBIN_NAME=$(echo "${lCSV_RULE}" | cut -d ':' -f3)
  if [[ -z "${lBIN_VENDOR}" ]]; then
    # backup mode for setting the vendor in the CPE to the software component
    lBIN_VENDOR="${lBIN_NAME}"
  fi
  lPURL_IDENTIFIER="pkg:binary/${lOS_IDENTIFIED/-*}/${lBIN_NAME}"
  lBIN_VERS=$(echo "${lCSV_RULE}" | cut -d ':' -f4-)

  if [[ -n "${lBIN_VERS}" ]]; then
    lPURL_IDENTIFIER+="@${lBIN_VERS}"
  fi
  if [[ -n "${lAPP_ARCH}" ]]; then
    lPURL_IDENTIFIER+="?arch=${lAPP_ARCH//\ /-}"
  fi
  if [[ "${lOS_IDENTIFIED}" != "generic" ]]; then
    if [[ -n "${lAPP_ARCH}" ]]; then
      lPURL_IDENTIFIER+="&"
    else
      lPURL_IDENTIFIER+="?"
    fi
    lPURL_IDENTIFIER+="distro=${lOS_IDENTIFIED}"
  fi

  echo "${lPURL_IDENTIFIER}"
}

build_cpe_identifier() {
  local lCSV_RULE="${1:-}"
  local lBIN_VENDOR=""
  local lBIN_NAME=""
  local lBIN_VERS=""
  local lCPE_LENGTH=""
  local lCPE_IDENTIFIER=""

  lBIN_VENDOR=$(echo "${lCSV_RULE}" | cut -d ':' -f2)
  lBIN_NAME=$(echo "${lCSV_RULE}" | cut -d ':' -f3)
  if [[ -z "${lBIN_VENDOR}" ]]; then
    # backup mode for setting the vendor in the CPE to the software component
    lBIN_VENDOR="${lBIN_NAME}"
  fi
  lBIN_VERS=$(echo "${lCSV_RULE}" | cut -d ':' -f4-)
  # our CPE identifier should have 13 fields - sometimes our lBIN_VERS has multiple fields -> we need to count our fields and fill the rest
  lCPE_IDENTIFIER="cpe:${CPE_VERSION}:a:${lBIN_VENDOR:-*}:${lBIN_NAME:-*}:${lBIN_VERS:-*}:"
  lCPE_LENGTH=$(echo "${lCPE_IDENTIFIER}" | tr ':' '\n' | wc -l)

  while [[ "${lCPE_LENGTH}" -lt 13 ]]; do
    lCPE_IDENTIFIER+='*:'
    lCPE_LENGTH=$(echo "${lCPE_IDENTIFIER}" | tr ':' '\n' | wc -l)
  done

  echo "${lCPE_IDENTIFIER}"
}

generate_strings() {
  local lBIN="${1:-}"
  local lBIN_FILE=""
  local lMD5_SUM=""
  local lBIN_NAME_REAL=""
  local lSTRINGS_OUTPUT=""

  if ! [[ -f "${lBIN}" ]]; then
    return
  fi

  lBIN_FILE=$(file -b "${lBIN}" || true)
  if [[ "${lBIN_FILE}" == *"text"* || "${lBIN_FILE}" == *" archive "* || "${lBIN_FILE}" == *" compressed "* ]]; then
    return
  fi

  lMD5_SUM="$(md5sum "${lBIN}")"
  lMD5_SUM="${lMD5_SUM/\ *}"
  lBIN_NAME_REAL="$(basename "${lBIN}")"
  lSTRINGS_OUTPUT="${LOG_PATH_MODULE}"/strings_bins/strings_"${lMD5_SUM}"_"${lBIN_NAME_REAL}".txt
  if ! [[ -f "${lSTRINGS_OUTPUT}" ]]; then
    strings "${lBIN}" | uniq > "${lSTRINGS_OUTPUT}" || true
  fi
}

bin_string_checker() {
  local lSTRICT="${1:-}"
  local lVERSION_IDENTIFIERS_ARR=()
  VERSION_IDENTIFIER="${VERSION_IDENTIFIER%\'}"
  VERSION_IDENTIFIER="${VERSION_IDENTIFIER/\'}"
  local lPACKAGING_SYSTEM="static_bin_analysis"

  # load VERSION_IDENTIFIER string into array for multi_grep handling
  # nosemgrep
  local IFS='&&'
  IFS='&&' read -r -a lVERSION_IDENTIFIERS_ARR <<< "${VERSION_IDENTIFIER}"

  local lBIN=""
  local lPURL_IDENTIFIER="NA"
  local lOS_IDENTIFIED=""
  local lMD5_SUM=""

  # check this - I think we do not really need this anymore
  if [[ ${RTOS} -eq 0 && "${SBOM_MINIMAL:-0}" -ne 1 ]]; then
    local FILE_ARR=( "${BINARIES[@]}" )
  fi
  # print_output "[*] Testing ${#FILE_ARR[@]} binaries against identifier ${VERSION_IDENTIFIER}"
  lOS_IDENTIFIED=$(distri_check)

  for lBIN in "${FILE_ARR[@]}"; do
    # print_output "[*] Testing ${lBIN} for versions"
    lMD5_SUM="$(md5sum "${lBIN}")"
    lMD5_SUM="${lMD5_SUM/\ *}"
    local lBIN_NAME_REAL=""
    BIN_NAME_REAL="$(basename "${lBIN}")"
    local lBIN_FILE=""
    lBIN_FILE=$(file -b "${lBIN}" || true)
    if [[ "${lBIN_FILE}" == *"text"* || "${lBIN_FILE}" == *" archive "* || "${lBIN_FILE}" == *" compressed "* ]]; then
      continue
    fi
    local lSTRINGS_OUTPUT="${LOG_PATH_MODULE}"/strings_bins/strings_"${lMD5_SUM}"_"${BIN_NAME_REAL}".txt
    if ! [[ -f "${lSTRINGS_OUTPUT}" ]]; then
      # print_output "[-] Warning: Strings for bin ${lBIN} not found"
      continue
    fi
    local lCONFIDENCE_LEVEL=3

    # print_output "[*] Testing $lBIN" "no_log"
    for (( j=0; j<${#lVERSION_IDENTIFIERS_ARR[@]}; j++ )); do
      local VERSION_IDENTIFIER="${lVERSION_IDENTIFIERS_ARR["${j}"]}"
      local lVERSION_FINDER=""
      [[ -z "${VERSION_IDENTIFIER}" ]] && continue
      # this is a workaround to handle the new multi_grep
      if [[ "${VERSION_IDENTIFIER: 0:1}" == '"' ]]; then
        VERSION_IDENTIFIER="${VERSION_IDENTIFIER/\"}"
        VERSION_IDENTIFIER="${VERSION_IDENTIFIER%\"}"
      fi
      if [[ ${RTOS} -eq 0 ]]; then
        if [[ "${lBIN_FILE}" == *ELF* || "${lBIN_FILE}" == *uImage* || "${lBIN_FILE}" == *Kernel\ Image* || "${lBIN_FILE}" == *"Linux\ kernel"* ]] ; then
          # print_output "[*] Testing $lBIN with version identifier ${VERSION_IDENTIFIER}" "no_log"
          lVERSION_FINDER=$(grep -o -a -E "${VERSION_IDENTIFIER}" "${lSTRINGS_OUTPUT}" | sort -u | head -1 || true)

          if [[ -n ${lVERSION_FINDER} ]]; then
            if [[ "${#lVERSION_IDENTIFIERS_ARR[@]}" -gt 1 ]] && [[ "$((j+1))" -lt "${#lVERSION_IDENTIFIERS_ARR[@]}" ]]; then
              # we found the first identifier and now we need to check the other identifiers also
              print_output "[+] Found sub identifier ${ORANGE}${VERSION_IDENTIFIER}${GREEN} in binary ${ORANGE}${lBIN}${GREEN}" "no_log"
              continue
            fi
            print_ln "no_log"
            print_output "[+] Version information found ${RED}${lVERSION_FINDER}${NC}${GREEN} in binary ${ORANGE}$(print_path "${lBIN}")${GREEN} (license: ${ORANGE}${LIC}${GREEN}) (${ORANGE}static${GREEN})."
            CSV_RULE=$(get_csv_rule "${lVERSION_FINDER}" "${CSV_REGEX}")
            CSV_RULE="${CSV_RULE//\ }"
            write_csv_log "${lBIN}" "${lAPP_NAME}" "${lVERSION_FINDER}" "${CSV_RULE}" "${LIC}" "${TYPE}"
            check_for_s08_csv_log "${S08_CSV_LOG}"

            lMD5_CHECKSUM="$(md5sum "${lBIN}" | awk '{print $1}')"
            lSHA256_CHECKSUM="$(sha256sum "${lBIN}" | awk '{print $1}')"
            lSHA512_CHECKSUM="$(sha512sum "${lBIN}" | awk '{print $1}')"

            lBIN_FILE=$(echo "${lBIN_FILE}" | cut -d ',' -f2)
            lBIN_ARCH=${lBIN_FILE#\ }

            lCPE_IDENTIFIER=$(build_cpe_identifier "${CSV_RULE}")
            lPURL_IDENTIFIER=$(build_generic_purl "${CSV_RULE}" "${lOS_IDENTIFIED}" "${lBIN_ARCH}")

            lAPP_MAINT=$(echo "${CSV_RULE}" | cut -d ':' -f2)
            lAPP_NAME=$(echo "${CSV_RULE}" | cut -d ':' -f3)
            lAPP_VERS=$(echo "${CSV_RULE}" | cut -d ':' -f4-5)

            # add source file path information to our properties array:
            local lPROP_ARRAY_INIT_ARR=()
            lPROP_ARRAY_INIT_ARR+=( "source_path:${lBIN}" )
            lPROP_ARRAY_INIT_ARR+=( "source_arch:${lBIN_ARCH}" )
            lPROP_ARRAY_INIT_ARR+=( "source_details:${lBIN_FILE}" )
            lPROP_ARRAY_INIT_ARR+=( "identifer_detected:${lVERSION_FINDER}" )
            lPROP_ARRAY_INIT_ARR+=( "minimal_identifier:${CSV_RULE}" )
            lPROP_ARRAY_INIT_ARR+=( "confidence:$(get_confidence_string ${lCONFIDENCE_LEVEL})" )

            build_sbom_json_properties_arr "${lPROP_ARRAY_INIT_ARR[@]}"

            # build_json_hashes_arr sets lHASHES_ARR globally and we unset it afterwards
            # final array with all hash values
            if ! build_sbom_json_hashes_arr "${lBIN}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lPACKAGING_SYSTEM:-NA}" "${lCONFIDENCE_LEVEL}"; then
              print_output "[*] Already found results for ${lAPP_NAME} / ${lAPP_VERS}" "no_log"
              continue
            fi

            # create component entry - this allows adding entries very flexible:
            build_sbom_json_component_arr "${lPACKAGING_SYSTEM}" "${lAPP_TYPE:-library}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lAPP_MAINT:-NA}" "${LIC:-NA}" "${lCPE_IDENTIFIER:-NA}" "${lPURL_IDENTIFIER:-NA}" "${lAPP_DESC:-NA}"

            write_log "${lPACKAGING_SYSTEM};${lBIN:-NA};${lMD5_CHECKSUM:-NA}/${lSHA256_CHECKSUM:-NA}/${lSHA512_CHECKSUM:-NA};${lAPP_NAME};${lVERSION_FINDER:-NA};${CSV_RULE};${LIC};maintainer unknown;${lBIN_FILE};${lCPE_IDENTIFIER};${lPURL_IDENTIFIER};${SBOM_COMP_BOM_REF:-NA};DESC" "${S08_CSV_LOG}"
            # we test the next binary
            continue 2
          fi
        else
          if [[ "${lSTRICT}" == "multi_grep" ]]; then
            # we do not test multi_grep on other things then ELF files!
            continue
          fi
          # this is for all other "non-text" stuff -> this gets a very low confidence rating
          # the false positive rate is higher
          lVERSION_FINDER=$(grep -o -a -E "${VERSION_IDENTIFIER}" "${lSTRINGS_OUTPUT}" | sort -u | head -1 || true)

          if [[ -n ${lVERSION_FINDER} ]]; then
            if [[ "${#lVERSION_IDENTIFIERS_ARR[@]}" -gt 1 ]] && [[ "$((j+1))" -lt "${#lVERSION_IDENTIFIERS_ARR[@]}" ]]; then
              # we found the first identifier and now we need to check the other identifiers also
              print_output "[+] Found sub identifier ${ORANGE}${VERSION_IDENTIFIER}${GREEN} in file ${ORANGE}${lBIN}${GREEN}" "no_log"
              continue
            fi
            print_ln "no_log"
            print_output "[+] Version information found ${RED}${lVERSION_FINDER}${NC}${GREEN} in file ${ORANGE}$(print_path "${lBIN}")${GREEN} (license: ${ORANGE}${LIC}${GREEN}) (${ORANGE}static${GREEN})."
            CSV_RULE=$(get_csv_rule "${lVERSION_FINDER}" "${CSV_REGEX}")
            CSV_RULE="${CSV_RULE//\ }"
            write_csv_log "${lBIN}" "${lAPP_NAME}" "${lVERSION_FINDER}" "${CSV_RULE}" "${LIC}" "${TYPE}"
            check_for_s08_csv_log "${S08_CSV_LOG}"

            lMD5_CHECKSUM="$(md5sum "${lBIN}" | awk '{print $1}')"
            lSHA256_CHECKSUM="$(sha256sum "${lBIN}" | awk '{print $1}')"
            lSHA512_CHECKSUM="$(sha512sum "${lBIN}" | awk '{print $1}')"
            lCPE_IDENTIFIER=$(build_cpe_identifier "${CSV_RULE}")
            lBIN_ARCH=$(echo "${lBIN_FILE}" | cut -d ',' -f2)
            lBIN_ARCH=${lBIN_ARCH#\ }
            lPURL_IDENTIFIER=$(build_generic_purl "${CSV_RULE}" "${lOS_IDENTIFIED}" "${lBIN_ARCH}")

            lAPP_MAINT=$(echo "${CSV_RULE}" | cut -d ':' -f2)
            lAPP_NAME=$(echo "${CSV_RULE}" | cut -d ':' -f3)
            lAPP_VERS=$(echo "${CSV_RULE}" | cut -d ':' -f4-5)

            local lCONFIDENCE_LEVEL=1

            # add source file path information to our properties array:
            local lPROP_ARRAY_INIT_ARR=()
            lPROP_ARRAY_INIT_ARR+=( "source_path:${lBIN}" )
            lPROP_ARRAY_INIT_ARR+=( "source_arch:${lBIN_ARCH}" )
            lPROP_ARRAY_INIT_ARR+=( "source_details:${lBIN_FILE}" )
            lPROP_ARRAY_INIT_ARR+=( "identifer_detected:${lVERSION_FINDER}" )
            lPROP_ARRAY_INIT_ARR+=( "minimal_identifier:${CSV_RULE}" )
            lPROP_ARRAY_INIT_ARR+=( "confidence:$(get_confidence_string ${lCONFIDENCE_LEVEL})" )

            build_sbom_json_properties_arr "${lPROP_ARRAY_INIT_ARR[@]}"

            # build_json_hashes_arr sets lHASHES_ARR globally and we unset it afterwards
            # final array with all hash values
            if ! build_sbom_json_hashes_arr "${lBIN}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lPACKAGING_SYSTEM:-NA}" "${lCONFIDENCE_LEVEL}"; then
              print_output "[*] Already found results for ${lAPP_NAME} / ${lAPP_VERS}" "no_log"
              continue
            fi

            # create component entry - this allows adding entries very flexible:
            build_sbom_json_component_arr "${lPACKAGING_SYSTEM}" "${lAPP_TYPE:-library}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lAPP_MAINT:-NA}" "${LIC:-NA}" "${lCPE_IDENTIFIER:-NA}" "${lPURL_IDENTIFIER:-NA}" "${lAPP_DESC:-NA}"

            write_log "${lPACKAGING_SYSTEM};${lBIN:-NA};${lMD5_CHECKSUM:-NA}/${lSHA256_CHECKSUM:-NA}/${lSHA512_CHECKSUM:-NA};${lAPP_NAME};${lVERSION_FINDER:-NA};${CSV_RULE};${LIC};maintainer unknown;${lBIN_FILE};${lCPE_IDENTIFIER};${lPURL_IDENTIFIER};${SBOM_COMP_BOM_REF:-NA};DESC" "${S08_CSV_LOG}"
            continue 2
          fi
        fi
      else
        # this is RTOS mode
        # echo "Testing $lBIN - $VERSION_IDENTIFIER"
        lVERSION_FINDER=$(grep -o -a -E "${VERSION_IDENTIFIER}" "${lSTRINGS_OUTPUT}" | sort -u | head -1 || true)

        if [[ -n ${lVERSION_FINDER} ]]; then
          if [[ "${#lVERSION_IDENTIFIERS_ARR[@]}" -gt 1 ]] && [[ "$((j+1))" -lt "${#lVERSION_IDENTIFIERS_ARR[@]}" ]]; then
            # we found the first identifier and now we need to check the other identifiers also
            print_output "[+] Found sub identifier ${ORANGE}${VERSION_IDENTIFIER}${GREEN} in binary ${ORANGE}${lBIN}${GREEN}" "no_log"
            continue
          fi
          print_ln "no_log"
          print_output "[+] Version information found ${RED}${lVERSION_FINDER}${NC}${GREEN} in binary ${ORANGE}$(print_path "${lBIN}")${GREEN} (license: ${ORANGE}${LIC}${GREEN}) (${ORANGE}static${GREEN})."
          CSV_RULE=$(get_csv_rule "${lVERSION_FINDER}" "${CSV_REGEX}")
          CSV_RULE="${CSV_RULE//\ }"
          write_csv_log "${lBIN}" "${lAPP_NAME}" "${lVERSION_FINDER}" "${CSV_RULE}" "${LIC}" "${TYPE}"
          check_for_s08_csv_log "${S08_CSV_LOG}"

          lMD5_CHECKSUM="$(md5sum "${lBIN}" | awk '{print $1}')"
          lSHA256_CHECKSUM="$(sha256sum "${lBIN}" | awk '{print $1}')"
          lSHA512_CHECKSUM="$(sha512sum "${lBIN}" | awk '{print $1}')"
          lCPE_IDENTIFIER=$(build_cpe_identifier "${CSV_RULE}")
          lBIN_ARCH=$(echo "${lBIN_FILE}" | cut -d ',' -f2)
          lBIN_ARCH=${lBIN_ARCH#\ }
          lPURL_IDENTIFIER=$(build_generic_purl "${CSV_RULE}" "${lOS_IDENTIFIED}" "${lBIN_ARCH}")

          lAPP_MAINT=$(echo "${CSV_RULE}" | cut -d ':' -f2)
          lAPP_NAME=$(echo "${CSV_RULE}" | cut -d ':' -f3)
          lAPP_VERS=$(echo "${CSV_RULE}" | cut -d ':' -f4-5)

          local lCONFIDENCE_LEVEL=1

          # add source file path information to our properties array:
          local lPROP_ARRAY_INIT_ARR=()
          lPROP_ARRAY_INIT_ARR+=( "source_path:${lBIN}" )
          lPROP_ARRAY_INIT_ARR+=( "source_arch:${lBIN_ARCH}" )
          lPROP_ARRAY_INIT_ARR+=( "source_details:${lBIN_FILE}" )
          lPROP_ARRAY_INIT_ARR+=( "identifer_detected:${lVERSION_FINDER}" )
          lPROP_ARRAY_INIT_ARR+=( "minimal_identifier:${CSV_RULE}" )
          lPROP_ARRAY_INIT_ARR+=( "confidence:$(get_confidence_string ${lCONFIDENCE_LEVEL})" )

          build_sbom_json_properties_arr "${lPROP_ARRAY_INIT_ARR[@]}"

          # build_json_hashes_arr sets lHASHES_ARR globally and we unset it afterwards
          # final array with all hash values
          if ! build_sbom_json_hashes_arr "${lBIN}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lPACKAGING_SYSTEM:-NA}" "${lCONFIDENCE_LEVEL}"; then
            print_output "[*] Already found results for ${lAPP_NAME} / ${lAPP_VERS}" "no_log"
            continue
          fi

          # create component entry - this allows adding entries very flexible:
          build_sbom_json_component_arr "${lPACKAGING_SYSTEM}" "${lAPP_TYPE:-library}" "${lAPP_NAME:-NA}" "${lAPP_VERS:-NA}" "${lAPP_MAINT:-NA}" "${LIC:-NA}" "${lCPE_IDENTIFIER:-NA}" "${lPURL_IDENTIFIER:-NA}" "${lAPP_DESC:-NA}"

          write_log "${lPACKAGING_SYSTEM};${lBIN:-NA};${lMD5_CHECKSUM:-NA}/${lSHA256_CHECKSUM:-NA}/${lSHA512_CHECKSUM:-NA};${lAPP_NAME};${lVERSION_FINDER:-NA};${CSV_RULE};${LIC};maintainer unknown;${lBIN_FILE};${lCPE_IDENTIFIER};${lPURL_IDENTIFIER};${SBOM_COMP_BOM_REF:-NA};DESC" "${S08_CSV_LOG}"
          # we test the next binary
          continue 2
        fi
      fi
      continue 2
    done
  done
}

recover_wait_pids() {
  local lTEMP_PIDS_ARR=()
  local lPID=""
  # check for really running PIDs and re-create the array
  for lPID in "${WAIT_PIDS_S09[@]}"; do
    # print_output "[*] max pid protection: ${#WAIT_PIDS[@]}"
    if [[ -e /proc/"${lPID}" ]]; then
      lTEMP_PIDS_ARR+=( "${lPID}" )
    fi
  done
  # print_output "[!] S09 - really running pids: ${#lTEMP_PIDS_ARR[@]}"

  # recreate the array with the current running PIDS
  WAIT_PIDS_S09=()
  WAIT_PIDS_S09=("${lTEMP_PIDS_ARR[@]}")
}

