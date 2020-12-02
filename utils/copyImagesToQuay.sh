#!/bin/bash -e
#
# Copyright (c) 2019-2020 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#

# script to copy latest tags from a list of images into quay.io/eclipse/che- namespace
# REQUIRES: 
#    * skopeo >=0.40 (for authenticated registry queries)
#    * jq to do json queries
# 
# https://registry.redhat.io is v2 and requires authentication to query, so login in first like this:
# docker login registry.redhat.io -u=USERNAME -p=PASSWORD

command -v jq >/dev/null 2>&1 || { echo "jq is not installed. Aborting."; exit 1; }
command -v skopeo >/dev/null 2>&1 || { echo "skopeo is not installed. Aborting."; exit 1; }
checkVersion() {
  if [[  "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ]]; then
    # echo "[INFO] $3 version $2 >= $1, can proceed."
	true
  else 
    echo "[ERROR] Must install $3 version >= $1"
    exit 1
  fi
}
checkVersion 0.40 "$(skopeo --version | sed -e "s/skopeo version //")" skopeo

DOCOPY=1      # normally, do the copy; optionally can just list images to copy
AUTH_TOKEN="" # API token to use to make changes to the repos (if applicable)
VERBOSE=0	# more output
WORKDIR=$(pwd)

usage () {
	echo "
1. Log into quay.io using a QUAY_USER that has permission to create repos under quay.io/eclipse. 

2. Go to you user's settings page, and click 'Generate Encrypted Password' to get a token

3. Export that token and log in via commandline

export QUAY_TOKEN=\"your token goes here\"
echo \"\${QUAY_TOKEN}\" | podman login -u=\"\${QUAY_USER}\" --password-stdin quay.io

4. Repeat the above process for docker.io - you just need a login that won't be rate-limited 
when reading digest information with skopeo:

export DOCKER_TOKEN=\"your token goes here\"
echo \"\${DOCKER_TOKEN}\" | podman login -u=\"\${DOCKER_USER}\" --password-stdin docker.io

5. Finally, run this script. Note that if your connection to quay.io times out pulling or pushing, 
you can re-run this script until it's successful.

Usage:   $0 -f [IMAGE LIST FILE] [--nocopy]
Example: $0 -f copyImagesToQuay.txt --nocopy

Options: 
	-v               verbose output
	--no-copy        just collect the list of destination images + SHAs, but don't actually do the copy
	--auth-token     if you want to also set user/group/visibility settings on the target repo, provide your auth token
	--help, -h       help
"
	exit 
}

if [[ $# -lt 1 ]]; then usage; exit; fi

while [[ "$#" -gt 0 ]]; do
  case $1 in
    '-w') WORKDIR="$2"; shift 1;;
    '-f') LISTFILE="$2"; shift 1;;
    '-v') VERBOSE=1; shift 0;;
	'--no-copy') DOCOPY=0; shift 0;;
	'--auth-token') AUTH_TOKEN="$2"; shift 1;;
    '--help'|'-h') usage;;
    *) OTHER="${OTHER} $1"; shift 0;; 
  esac
  shift 1
done

# check for valid list file
if [[ ! $LISTFILE ]]; then usage; fi
if [[ ! -r $LISTFILE ]] && [[ ! -r ${WORKDIR}/${LISTFILE} ]]; then usage; fi

curl_it ()
{
	# 1 - method = PUT, POST, GET
	# 2 - api path, see https://docs.quay.io/api/swagger/#!/permission/changeUserPermissions for syntax
	# 3 - JSON payload, see https://docs.quay.io/api/swagger/#!/permission/changeUserPermissions for examples

	if [[ $VERBOSE -gt 0 ]]; then
		set -x
		curl -sSL -X "${1}" -H "Authorization: Bearer $AUTH_TOKEN" -H "Content-Type: application/json" "https://quay.io/api/v1/repository/${imagePath}/${2}" -d "${3}" | jq .
		set +x
	else
		curl -sSL -X "${1}" -H "Authorization: Bearer $AUTH_TOKEN" -H "Content-Type: application/json" "https://quay.io/api/v1/repository/${imagePath}/${2}" -d "${3}" | grep "not allowed" || true
	fi
}

while IFS= read -r image; do
	if [[ ${image} ]]; then 
		# transform source image to new image
		imageNew="${image/docker.io\//che--}"
		imageNew="quay.io/eclipse/${imageNew//\//--}"
		if [[ ${imageNew} != *":"* ]] && [[ ${imageNew} != *"sha256"* ]]; then 
			# image has no tag or sha, so assume :latest
			imageNew="${imageNew}:latest"
		fi
		# get the digest of the image and use that instead of a potentially moving tag
		digest=""
		if [[ ${DOCOPY} -eq 1 ]]; then
			if [[ $VERBOSE -gt 0 ]]; then set -x; fi
			digest="$(skopeo inspect docker://${image} | yq -r '.Digest' | sed -r -e "s#sha256:#-#g")"
			echo "
[INFO] Skopeo copy $image to
        ${imageNew}${digest} ... "
			# note that the target image in quay must exist; or the user pushing must be an administrator to create the repo on the fly
			skopeo copy --all "docker://${image}" "docker://${imageNew}${digest}"
			set +x
		fi

		# now make sure we have valid permissions on the repo: 
		if [[ ${AUTH_TOKEN} ]]; then
			imagePath=${imageNew%%:*}
			imagePath=${imagePath#*/}
			echo "[INFO] Update https://quay.io/repository/${imagePath}?tab=settings ..."
			echo "[INFO]  + Make public ..."
			curl_it POST changevisibility '{ "visibility": "public" }'
			echo "[INFO]  + Add team owner = admin ..."
			curl_it PUT permissions/team/owners '{ "role": "admin" }'
			echo "[INFO]  + Add team creators = write ..."
			curl_it PUT permissions/team/creators '{ "role": "write" }'
			echo "[INFO]  + Add user robots (2) = write ..."
			curl_it PUT permissions/user/eclipse+centos_ci '{ "role": "write" }'
			curl_it PUT permissions/user/eclipse+gh_actions_dockerfiles '{ "role": "write" }'
		fi
		digest=""
	fi
done < <(grep -v '^ *#' < ${LISTFILE}) # exclude commented lines
