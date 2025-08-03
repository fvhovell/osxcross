#!/usr/bin/env bash

PERSONAL_ACCESS_TOKEN="$1"
if [[ -z ${PERSONAL_ACCESS_TOKEN} ]]; then
  echo "Usage: $0 [PERSONAL_ACCESS_TOKEN]"
  exit 1
fi

RELEASE_VERSION="v0.2.0"
GITLAB_BASE_URL="https://gitlab.svc.lan"
CI_PROJECT_ID="173"
CI_PROJECT_PATH="opensource/macos/osxcross"
PROJECT_BASE_URL="${GITLAB_BASE_URL}/api/v4/projects/${CI_PROJECT_ID}"
PACKAGE_REGISTRY_URL="${PROJECT_BASE_URL}/packages/generic"
RELEASES_URL="${PROJECT_BASE_URL}/releases/${RELEASE_VERSION}/assets/links"
PACKAGE_NAME=MacOSX-SDK

get_package_id_of_file() {
  local FILE=$1
  local PACKAGE_VERSION=$2

  local PACKAGE_ID=$(
    curl --silent \
      --request GET \
      --header "PRIVATE-TOKEN: ${PERSONAL_ACCESS_TOKEN}" \
      --header "Accept: application/json" \
      ${PROJECT_BASE_URL}/packages \
    | jq ".[] | select(.name == \"${PACKAGE_NAME}\" and .version == \"${PACKAGE_VERSION}\") | .id"
  )
  #echo "Found packageId for ${FILE}: ${PACKAGE_ID}" >&2
  echo "${PACKAGE_ID}"
}

get_package_file_ids_of_file() {
  local FILE=$1
  local PACKAGE_ID=$2
  local PACKAGE_FILE_IDS=$(
    curl --silent \
      --request GET \
      --header "PRIVATE-TOKEN: ${PERSONAL_ACCESS_TOKEN}" \
      --header "Accept: application/json" \
      ${PROJECT_BASE_URL}/packages/${PACKAGE_ID}/package_files \
    | jq ".[] | select(.file_name == \"${FILE}\") | .id"
  )
  #echo "Found packageFileIds for ${FILE}: $(echo "${PACKAGE_FILE_IDS}" | tr "\n" " ")" >&2
  echo "${PACKAGE_FILE_IDS}"
}

delete_file() {
  local FILE=$1

  local MACOS_VERSION=${FILE/MacOSX/}
  local MACOS_VERSION=${MACOS_VERSION/.sdk.tar.xz/}
  local PACKAGE_VERSION=${MACOS_VERSION}
  local PACKAGE_ID=$(get_package_id_of_file ${FILE} ${PACKAGE_VERSION})
  if [[ -z ${PACKAGE_ID} ]]; then
    echo "File ${FILE} already deleted."
    return
  fi
  local PACKAGE_FILE_IDS=$(get_package_file_ids_of_file ${FILE} ${PACKAGE_ID})
  for PACKAGE_FILE_ID in ${PACKAGE_FILE_IDS}; do
    echo -n "Deleting package-file for ${FILE} with packageId ${PACKAGE_ID} and packageFileId ${PACKAGE_FILE_ID}: " >&2
    local RESULT=$(
      curl --silent --request DELETE \
        --header "PRIVATE-TOKEN: ${PERSONAL_ACCESS_TOKEN}" \
        "${PROJECT_BASE_URL}/packages/${PACKAGE_ID}/package_files/${PACKAGE_FILE_ID}";
    )
    echo "${RESULT} - done." >&2
  done
  echo -n "Deleting package for ${FILE} with packageId ${PACKAGE_ID}: " >&2
  local RESULT=$(
    curl --silent --request DELETE \
      --header "PRIVATE-TOKEN: ${PERSONAL_ACCESS_TOKEN}" \
      "${PROJECT_BASE_URL}/packages/${PACKAGE_ID}"
  )
  echo "${RESULT} - done."
}

upload_file() {
  local FILE=$1
  local MACOS_VERSION=${FILE/MacOSX/}
  local MACOS_VERSION=${MACOS_VERSION/.sdk.tar.xz/}
  local PACKAGE_VERSION=${MACOS_VERSION}
  local PACKAGE_ID=$(get_package_id_of_file ${FILE} ${PACKAGE_VERSION})
  if [[ -n ${PACKAGE_ID} ]]; then
    echo "File ${FILE} already uploaded as packageId ${PACKAGE_ID}"
    return
  fi
  echo -n "Uploading ${FILE} as package ${PACKAGE_NAME}/${PACKAGE_VERSION}: " >&2
  local RESULT=$(
    curl --silent \
      --header "PRIVATE-TOKEN: ${PERSONAL_ACCESS_TOKEN}" \
      --header "Content-Type: multipart/form-data" \
      --upload-file ${FILE} \
      "${PACKAGE_REGISTRY_URL}/${PACKAGE_NAME}/${PACKAGE_VERSION}/${FILE}"
  )
  echo "done." >&2
}

get_release_assets() {
  local RELEASE=$1
  local RESULT=$(
    curl --silent \
      --request GET \
      --header "PRIVATE-TOKEN: ${PERSONAL_ACCESS_TOKEN}" \
      --header "Accept: application/json" \
      ${PROJECT_BASE_URL}/releases/${RELEASE}/assets/links \
  )
  echo "${RESULT}"
}

get_asset_link_id_of_file() {
  local RELEASE=$1
  local FILE=$2
  local LINK_ID=$(
    get_release_assets ${RELEASE} \
    | jq ".[] | select(.name == \"${FILE}\") | .id"
  )
  #echo "Found linkId for ${FILE}: ${LINK_ID}" >&2
  echo "${LINK_ID}"
}

remove_link() {
  local RELEASE=$1
  local FILE=$2

  LINK_ID=$(get_asset_link_id_of_file ${RELEASE} ${FILE})
  if [[ -z ${LINK_ID} ]]; then
    echo "Asset link already deleted for file ${FILE}" >&2
    return
  fi

  echo -n "Deleting asset link ${LINK_ID} for file ${FILE}: " >&2
  local RESULT=$(
    curl --silent --request DELETE \
      --header "PRIVATE-TOKEN: ${PERSONAL_ACCESS_TOKEN}" \
      "${RELEASES_URL}/${LINK_ID}" \
    | jq ".id"
  )
  echo "done." >&2
}

add_link() {
  local RELEASE=$1
  local FILE=$2

  local MACOS_VERSION=${FILE/MacOSX/}
  local MACOS_VERSION=${MACOS_VERSION/.sdk.tar.xz/}
  local PACKAGE_VERSION=${MACOS_VERSION}
  local PACKAGE_ID=$(get_package_id_of_file ${FILE} ${PACKAGE_VERSION})
  if [[ -z ${PACKAGE_ID} ]]; then
    echo "No packageId found for file ${FILE}" >&2
    return
  fi

  local PACKAGE_FILE_IDS=$(get_package_file_ids_of_file ${FILE} ${PACKAGE_ID})
  if [[ -z ${PACKAGE_FILE_IDS} ]]; then
    echo "No packageFileId found for file ${FILE}" >&2
    return
  fi
  local PACKAGE_FILE_ID=$(echo "${PACKAGE_FILE_IDS}" | head -n 1)

  echo -n "Adding link in release ${RELEASE} to packageFileId ${PACKAGE_FILE_ID} for ${FILE}: "
  local RESULT=$(
    curl --silent --request POST \
      --header "PRIVATE-TOKEN: ${PERSONAL_ACCESS_TOKEN}" \
      --data name="${FILE}" \
      --data link_type="package" \
      --data url="${GITLAB_BASE_URL}/${CI_PROJECT_PATH}/-/package_files/${PACKAGE_FILE_ID}/download" \
      "${RELEASES_URL}"
  )
  echo " - done." >&2
}

FILES=(*.sdk.tar.xz)
for FILE in ${FILES[@]}; do
  echo "=== ${FILE}" >&2
  remove_link ${RELEASE_VERSION} ${FILE}
  delete_file ${FILE}
  upload_file ${FILE}
  add_link ${RELEASE_VERSION} ${FILE}
done

get_release_assets ${RELEASE_VERSION} | jq .
