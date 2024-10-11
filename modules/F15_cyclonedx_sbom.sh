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

# Description:  This module generates a minimal json SBOM from the identified software inventory
#               via cyclonedx - https://github.com/CycloneDX/cyclonedx-cli#csv-format

# shellcheck disable=SC2034

F15_cyclonedx_sbom() {
  module_log_init "${FUNCNAME[0]}"
  module_title "CycloneDX SBOM converter"
  pre_module_reporter "${FUNCNAME[0]}"

  local lVERSION=""
  local lCHKSUM=""
  # local lBIN_NAME=""
  # local lSTRIPPED_VER=""
  local lLICENSE=""
  local lTYPE=""
  local lMIME_TYPE=""
  local lSUPPLIER=""
  local lCPE=""
  local lPURL=""
  local lNEG_LOG=0

  if ! command -v cyclonedx > /dev/null; then
    module_end_log "${FUNCNAME[0]}" "${lNEG_LOG}"
    return
  fi

  if [[ -f "${S08_CSV_LOG}" ]] && [[ "$(wc -l "${S08_CSV_LOG}" | awk '{print $1}')" -gt 1 ]]; then
    if [[ -f "${F15_CSV_LOG}" ]]; then
      rm "${F15_CSV_LOG}"
    fi
    if [[ -f "${CSV_DIR}"/f15_cyclonedx_sbom.json ]]; then
      rm "${CSV_DIR}"/f15_cyclonedx_sbom.json
    fi

    write_csv_log "Type" "MimeType" "Supplier" "Author" "Publisher" "Group" "Name" "Version" "Scope" "LicenseExpressions" "LicenseNames" "Copyright" "Cpe" "Purl" "Modified" "SwidTagId" "SwidName" "SwidVersion" "SwidTagVersion" "SwidPatch" "SwidTextContentType" "SwidTextEncoding" "SwidTextContent" "SwidUrl" "MD5" "SHA-1" "SHA-256" "SHA-512" "BLAKE2b-256" "BLAKE2b-384" "BLAKE2b-512" "SHA-384" "SHA3-256" "SHA3-384" "SHA3-512" "BLAKE3" "Description"
    print_output "[*] Collect available SBOM details ..." "no_log"

    # we build a csv that can be handled via cyclonedx
    while IFS=";" read -r COL1 COL2 COL3 COL4 COL5 COL6 COL7 COL8 COL9 COL10 COL11 COL12; do
      print_output "[*] Generating SBOM entry: ${COL1} - ${COL2} - ${COL3} - ${COL4} - ${COL5} - ${COL6} - ${COL7} - ${COL8} - ${COL9} - ${COL10} - ${COL11} - ${COL12}" "no_log"
      lTYPE="${COL1}"
      # we currently hard code it to application - Todo: we need to define further rules
      lTYPE=""
      # local lBINARY="${COL2}"
      lCHKSUM="${COL3}"
      lMD5_CHKSUM=${lCHKSUM/\/*}
      lSHA256_CHKSUM=${lCHKSUM/\/*}
      lSHA256_CHKSUM=$(echo "${lCHKSUM}" | cut -d '/' -f2)
      lSHA512_CHKSUM=${lCHKSUM/*\/}
      lBIN_NAME="${COL4}"
      # COL5 -> identified version
      lVERSION="${COL5}"
      if [[ "${COL6}" == "NA" ]]; then
        lSTRIPPED_VER="${COL5}"
      else
        # already post-processed version
        lSTRIPPED_VER="${COL6}"
      fi
      if [[ "${lSTRIPPED_VER}" == ":"* ]]; then
        # we have a version entry from our static analysis mechanism
        lSTRIPPED_VER=$(echo "${lSTRIPPED_VER}" | cut -d ':' -f4-)
      elif [[ "${COL1}" == "static_distri_analysis" ]]; then
        # additionally we need to parse the entries from static_distri_analysis (module s06)
        lSTRIPPED_VER=$(echo "${lSTRIPPED_VER}" | cut -d ':' -f4)
      fi
      lLICENSE="${COL7}"
      lMAINTAINER="${COL8}"
      # Todo
      lARCH="${COL9:-NA}"
      lCPE="${COL10:-NA}"
      lCPE="${lCPE//\ /-}"
      lCPE="${lCPE//,/-}"
      # PURL - https://github.com/package-url/purl-spec/blob/master/README.rst
      lPURL="${COL11:-NA}"
      lDESC="${COL12:-NA}"
      # local lBOM_REF="bom-ref-todo"
      # Todo: we need to define this more in detail (image, font, executable, ...)
      # Currently we mainly have exectuables
      lMIME_TYPE="executable"
      # The supplier may often be the manufacturer, but may also be a distributor or repackager.
      # if we found a linux distri we can use this. If we set a VENDOR we can use this
      lSUPPLIER="${FW_VENDOR:-unknown}"

      if grep -q ";${lBIN_NAME}\;${lSTRIPPED_VER};.*;${lSHA512_CHKSUM};" "${F15_CSV_LOG}"; then
        # just to ensure we have not already reported the identifier
        print_output "[*] Removing duplicate SBOM entry: ${COL1} - ${COL2} - ${COL4} - ${COL5} - ${COL6} - ${COL7}" "no_log"
        continue
      fi
      lDESCRIPTION="SBOM entry generated by EMBA - type ${COL1} - originally identified version ${lVERSION}. Further description: ${lDESC}"
      write_csv_log "${lTYPE}" "${lMIME_TYPE}" "${lSUPPLIER}" "${lMAINTAINER}" "" "${COL1}" "${lBIN_NAME}" "${lSTRIPPED_VER:-NA}" "" "" "${lLICENSE:-NA}" "" "${lCPE}" "${lPURL}" "" "" "" "" "" "" "" "" "" "" "${lMD5_CHKSUM:-NA}" "" "${lSHA256_CHKSUM:-NA}" "${lSHA512_CHKSUM:-NA}" "" "" "" "" "" "" "" "" "${lDESCRIPTION}"
    done < <(tail -n +2 "${S08_CSV_LOG}" | sort -u)

    if [[ -f "${F15_CSV_LOG}" ]]; then
      print_output "[*] Converting CSV SBOM to Cyclonedx SBOM ..." "no_log"
      # our csv is with ";" as deliminiter. cyclonedx needs "," -> lets do a quick tranlation
      sed -i 's/\;/,/g' "${F15_CSV_LOG}"
      cyclonedx convert --input-file "${F15_CSV_LOG}" --output-file "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_json.json || print_error "[-] Error while generating json SBOM for CSV ${F15_CSV_LOG}"
      cyclonedx convert --output-format xml --input-file "${F15_CSV_LOG}" --output-file "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_xml.txt || print_error "[-] Error while generating xml SBOM for CSV ${F15_CSV_LOG}"
      cyclonedx convert --output-format protobuf --input-file "${F15_CSV_LOG}" --output-file "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_proto.txt || print_error "[-] Error while generating protobuf SBOM for CSV ${F15_CSV_LOG}"
      # cyclonedx convert --output-format spdxjson --input-file "${F15_CSV_LOG}" --output-file "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_spdx.txt || print_error "[-] Error while generating spdxjson SBOM for CSV ${F15_CSV_LOG}"
      if [[ -f "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_json.json ]]; then
        # clean the unicodes after converting
        sed -i 's/\\u0026/\&/g' "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_json.json
        sed -i 's/\\u002B/+/g' "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_json.json
        sed -i 's/\\u003C/</g' "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_json.json
        sed -i 's/\\u003E/>/g' "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_json.json
        sed -i 's/\\u007E/~/g' "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_json.json
      else
        print_output "[-] No SBOM created!"
      fi
    fi

    if [[ -f "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_json.json ]]; then
      print_output "[+] Cyclonedx SBOM in json and CSV format created:"
      print_output "$(indent "$(orange "-> Download SBOM as JSON${NC}")")" "" "${LOG_PATH_MODULE}/f15_cyclonedx_sbom_json.json"
      print_output "$(indent "$(orange "-> Download SBOM as XML${NC}")")" "" "${LOG_PATH_MODULE}/f15_cyclonedx_sbom_xml.txt"
      # print_output "$(indent "$(orange "-> Download SBOM as SPDX JSON${NC}")")" "" "${LOG_PATH_MODULE}/f15_cyclonedx_sbom_spdx.txt"
      print_output "$(indent "$(orange "-> Download SBOM as PROTOBUF${NC}")")" "" "${LOG_PATH_MODULE}/f15_cyclonedx_sbom_proto.txt"
      print_output "$(indent "$(orange "-> Download SBOM as CSV${NC}")")" "" "${F15_CSV_LOG}"
      print_output "$(indent "$(orange "-> Download SBOM as EMBA CSV${NC}")")" "" "${S08_CSV_LOG}"
      print_ln
      print_output "[+] Cyclonedx SBOM in json format:"
      print_ln
      tee -a "${LOG_FILE}" < "${LOG_PATH_MODULE}"/f15_cyclonedx_sbom_json.json
      print_ln
      local lNEG_LOG=1
    fi
  fi

  module_end_log "${FUNCNAME[0]}" "${lNEG_LOG}"
}
