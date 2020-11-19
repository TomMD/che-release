#!/bin/bash

#include common scripts
. ./cico_common.sh

loadJenkinsVars() {
    set +x
    eval "$(./env-toolkit load -f jenkins-env.json \
                              CHE_BOT_GITHUB_TOKEN \
                              CHE_MAVEN_SETTINGS \
                              CHE_GITHUB_SSH_KEY \
                              CHE_NPM_AUTH_TOKEN \
                              CHE_OSS_SONATYPE_GPG_KEY \
                              CHE_OSS_SONATYPE_PASSPHRASE \
                              RH_CHE_AUTOMATION_DOCKERHUB_USERNAME \
                              RH_CHE_AUTOMATION_DOCKERHUB_PASSWORD \
                              QUAY_ECLIPSE_CHE_USERNAME \
                              QUAY_ECLIPSE_CHE_PASSWORD \
                              QUAY_ECLIPSE_CHE_OPERATOR_KUBERNETES_USERNAME \
                              QUAY_ECLIPSE_CHE_OPERATOR_KUBERNETES_PASSWORD \
                              QUAY_ECLIPSE_CHE_OPERATOR_OPENSHIFT_USERNAME \
                              QUAY_ECLIPSE_CHE_OPERATOR_OPENSHIFT_PASSWORD)"
    export NPM_AUTH_TOKEN=${CHE_NPM_AUTH_TOKEN}                              
}

loadMvnSettingsGpgKey() {
    set +x
    mkdir $HOME/.m2
    #prepare settings.xml for maven and sonatype (central maven repository)
    echo $CHE_MAVEN_SETTINGS | base64 -d > $HOME/.m2/settings.xml 
    #load GPG key for sign artifacts
    echo $CHE_OSS_SONATYPE_GPG_KEY | base64 -d > $HOME/.m2/gpg.key
    #load SSH key for release process
    echo ${#CHE_OSS_SONATYPE_GPG_KEY}
    echo $CHE_GITHUB_SSH_KEY | base64 -d > $HOME/.ssh/id_rsa
    chmod 0400 $HOME/.ssh/id_rsa
    ssh-keyscan github.com >> ~/.ssh/known_hosts
    set -x
    gpg --import $HOME/.m2/gpg.key
}

installDeps(){
    set +x

    # enable epel and update to latest
    sudo yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    sudo yum -y update 
    sudo yum -y remove git*
    sudo yum install -y centos-release-scl-rh
    subscription-manager repos --enable=rhel-server-rhscl-7-rpms || true

    # update to git 2.18 via https://www.softwarecollections.org/en/scls/rhscl/rh-git218/
#     sudo yum install -y rh-git218 rh-git218-git-all rh-git218-runtime hub
#     # enable rh-git218 for all users/bash shells
#     echo "#!/bin/bash
# source scl_source enable rh-git218" > /etc/profile.d/enablerh-git218.sh && chmod +x /etc/profile.d/enablerh-git218.sh
#     # run the enablement script
#     /etc/profile.d/enablerh-git218.sh
#     alias git='scl enable rh-git218 bash -c git' # alias approach?
#     ls -1R /etc/opt/rh/rh-git218/
#     echo "---"
#     rpm -ql rh-git218
#     echo "---"
#     rpm -ql rh-git218-runtime
#     echo "---"
#     rpm -ql rh-git218-git
#     echo "---"
#     cat /opt/rh/rh-git218/enable
#     echo "---"

#     set -x
#     git --version 
#     scl enable rh-git218 bash -c git --version
#     echo "---"

    # update to git 2.24 via https://repo.ius.io/7/x86_64/packages/g/
    sudo yum install -y https://repo.ius.io/ius-release-el7.rpm https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm || true
    sudo yum install -y git224-all
    git --version || exit 1

    yum -y install skopeo
    yum -y install java-11-openjdk-devel
    mkdir -p /opt/apache-maven && curl -sSL https://downloads.apache.org/maven/maven-3/3.6.3/binaries/apache-maven-3.6.3-bin.tar.gz | tar -xz --strip=1 -C /opt/apache-maven
    export JAVA_HOME=/usr/lib/jvm/java-11-openjdk
    export PATH="/usr/lib/jvm/java-11-openjdk:/opt/apache-maven/bin:/usr/bin:${PATH:-/bin:/usr/bin}"
    export JAVACONFDIRS="/etc/java${JAVACONFDIRS:+:}${JAVACONFDIRS:-}"
    export M2_HOME="/opt/apache-maven"
    yum install -y yum-utils device-mapper-persistent-data lvm2
    curl -sL https://rpm.nodesource.com/setup_10.x | bash -
    yum-config-manager --add-repo https://dl.yarnpkg.com/rpm/yarn.repo
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce nodejs yarn gcc-c++ make jq hub
    yum install -y python3-pip wget yq podman
    yum install -y psmisc
    echo "BASH VERSION = $BASH_VERSION"

    # start docker daemon
    service docker start
}

evaluateCheVariables() {
    source VERSION
    echo "Che version: ${CHE_VERSION}"
    # derive branch from version
    BRANCH=${CHE_VERSION%.*}.x
    echo "Branch: ${BRANCH}"

    if [[ ${CHE_VERSION} == *".0" ]]; then
        BASEBRANCH="master"
    else
        BASEBRANCH="${BRANCH}"
    fi
    echo "Basebranch: ${BASEBRANCH}" 
    echo "Release che-parent: ${RELEASE_CHE_PARENT}"

    echo "Autorelease on nexus: ${AUTORELEASE_ON_NEXUS}"
}

releaseCheDocs() {
    tmpdir="$(mktemp -d)"
    pushd "${tmpdir}" >/dev/null || exit
    projectPath=eclipse/che-docs
    rm -f ./make-release.sh && curl -sSLO "https://raw.githubusercontent.com/${projectPath}/master/make-release.sh" && chmod +x ./make-release.sh
    ./make-release.sh --repo "git@github.com:${projectPath}" --version "${CHE_VERSION}" --trigger-release
    popd >/dev/null || exit 
}

releaseDashboard() {
    curl https://api.github.com/repos/eclipse/che-dashboard/actions/workflows/3152474/dispatches -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" -d "{\"ref\":\"master\",\"inputs\": {\"version\":\"${CHE_VERSION}\"} }"
}

releaseWorkspaceLoader() {
    curl https://api.github.com/repos/eclipse/che-workspace-loader/actions/workflows/3543888/dispatches -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" -d "{\"ref\":\"master\",\"inputs\": {\"version\":\"${CHE_VERSION}\"} }"
}

releaseCheServer() {
    set -x
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        cd che-parent
        mvn clean install -U -Pcodenvy-release -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE

        if [ $? -eq 0 ]; then
            echo 'Build Success!'
            echo 'Going to deploy artifacts'
            mvn clean deploy -Pcodenvy-release -DcreateChecksum=true -DautoReleaseAfterClose=$AUTORELEASE_ON_NEXUS -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE
            cd ..
        else
            echo 'Build Failed!'
            exit 1
        fi        
    fi

    cd che
    mvn clean install -U -Pcodenvy-release -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE

    if [ $? -eq 0 ]; then
        echo 'Build Success!'
        echo 'Going to deploy artifacts'
        mvn clean deploy -Pcodenvy-release -DcreateChecksum=true -DautoReleaseAfterClose=$AUTORELEASE_ON_NEXUS -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE
        cd ..
    else
        echo 'Build Failed!'
        exit 1
    fi
    set +x
}

releaseTypescriptDto() {
    cd che/typescript-dto
    sed -i build.sh -e "s/3.3-jdk-8/3.6.3-jdk-11/g"
    set +e
    ./build.sh
    set -e
    git checkout -- .
    cd ../..
}

buildCheServer() {
    set -x
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        cd che-parent
        mvn clean install -U -Pcodenvy-release -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE 
        cd .. 
    fi
    cd che
    mvn clean install -U -Pcodenvy-release -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE
    cd ..
    set +x
}


# TODO ensure usage of respective bugfix branches
checkoutProjects() {
    checkoutProject git@github.com:eclipse/che-parent
    checkoutProject git@github.com:eclipse/che
}

checkoutProject() {
    PROJECT="${1##*/}"
    echo "checking out project $PROJECT with ${BRANCH} branch"

    git clone $1
    cd $PROJECT
    git checkout ${BASEBRANCH}

    set -x
    set +e
    if [[ "${BASEBRANCH}" != "${BRANCH}" ]]; then
        git branch "${BRANCH}" || git checkout "${BRANCH}" && git pull origin "${BRANCH}"
        git push origin "${BRANCH}"
        git fetch origin "${BRANCH}:${BRANCH}"
        git checkout "${BRANCH}"
    fi
    set -e
    set +x
    cd ..

}

# TODO change it to someone else?
setupGitconfig() {
  git config --global user.name "Mykhailo Kuznietsov"
  git config --global user.email mkuznets@redhat.com

  # hub CLI configuration
  git config --global push.default matching
  export GITHUB_TOKEN=$CHE_BOT_GITHUB_TOKEN
}

createTags() {
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        tagAndCommit che-parent
    fi
    tagAndCommit che
}

tagAndCommit() {
    cd $1
    # this branch isn't meant to be pushed
    git checkout -b release-${CHE_VERSION}
    git commit -asm "Release version ${CHE_VERSION}"
    if [ $(git tag -l "$CHE_VERSION") ]; then
        echo "tag ${CHE_VERSION} already exists! recreating ..."
        git tag -d ${CHE_VERSION}
        git push origin :${CHE_VERSION}
        git tag "${CHE_VERSION}"
    else
        echo "[INFO] creating new tag ${CHE_VERSION}"
        git tag "${CHE_VERSION}"
    fi
    git push --tags
    echo "[INFO] tag created and pushed for $1"
    cd ..
}

 # KEEP RIGHT ORDER!!!
DOCKER_FILES_LOCATIONS=(
    che/dockerfiles/endpoint-watcher
    che/dockerfiles/keycloak
    che/dockerfiles/postgres
    che/dockerfiles/dev
    che/dockerfiles/che
    che/dockerfiles/dashboard-dev
    che/dockerfiles/e2e
)

IMAGES_LIST=(
    quay.io/eclipse/che-endpoint-watcher
    quay.io/eclipse/che-keycloak
    quay.io/eclipse/che-postgres
    quay.io/eclipse/che-dev
    quay.io/eclipse/che-server
    quay.io/eclipse/che-dashboard-dev
    quay.io/eclipse/che-e2e
)

REGISTRY="quay.io"
ORGANIZATION="eclipse"

buildImages() {
    echo "Going to build docker images"
    set -e
    set -o pipefail
    TAG=$1
  
    # stop / rm all containers
    if [[ $(docker ps -aq) != "" ]];then
        docker rm -f $(docker ps -aq)
    fi

    # BUILD IMAGES
    for image_dir in ${DOCKER_FILES_LOCATIONS[@]}
      do
        if [[ ${image_dir} == "che/dockerfiles/che" ]]; then
          bash $(pwd)/${image_dir}/build.sh --tag:${TAG} --build-arg:"CHE_DASHBOARD_VERSION=${CHE_VERSION},CHE_WORKSPACE_LOADER_VERSION=${CHE_VERSION}"  
        else
          bash $(pwd)/${image_dir}/build.sh --tag:${TAG} 
        fi
        if [[ $? -ne 0 ]]; then
           echo "ERROR:"
           echo "build of '${image_dir}' image is failed!"
           exit 1
        fi
      done
}

tagLatestImages() {
    for image in ${IMAGES_LIST[@]}
     do
         echo y | docker tag "${image}:$1" "${image}:latest"
         if [[ $? -ne 0 ]]; then
           die_with  "docker tag of '${image}' image is failed!"
         fi
     done
}

loginQuay() {
    if [[ -n "${QUAY_ECLIPSE_CHE_USERNAME}" ]] && [[ -n "${QUAY_ECLIPSE_CHE_PASSWORD}" ]]; then
        docker login -u "${QUAY_ECLIPSE_CHE_USERNAME}" -p "${QUAY_ECLIPSE_CHE_PASSWORD}" "${REGISTRY}"
    else
        echo "Could not login, missing credentials for pushing to the '${ORGANIZATION}' organization"
        die_with  "failed to login on Quay!"
    fi

    if [ -n "${RH_CHE_AUTOMATION_DOCKERHUB_USERNAME}" ] && [ -n "${RH_CHE_AUTOMATION_DOCKERHUB_PASSWORD}" ]; then
        docker login -u "${RH_CHE_AUTOMATION_DOCKERHUB_USERNAME}" -p "${RH_CHE_AUTOMATION_DOCKERHUB_PASSWORD}"
    else
        echo "Could not login, missing credentials for pushing to the docker.io"
    fi
}

pushImagesOnQuay() {
    #PUSH IMAGES
    for image in ${IMAGES_LIST[@]}
        do
            echo y | docker push "${image}:$1"
            if [[ $2 == "pushLatest" ]]; then
                echo y | docker push "${image}:latest"
            fi
            if [[ $? -ne 0 ]]; then
            die_with  "docker push of '${image}' image is failed!"
            fi
        done
}

commitChangeOrCreatePR() {
    set +e

    aVERSION="$1"
    aBRANCH="$2"
    PR_BRANCH="$3"

    COMMIT_MSG="[release] Bump to ${aVERSION} in ${aBRANCH}"

    # commit change into branch
    git commit -asm "${COMMIT_MSG}"
    git pull origin "${aBRANCH}"

    PUSH_TRY="$(git push origin "${aBRANCH}")"
    # shellcheck disable=SC2181
    if [[ $? -gt 0 ]] || [[ $PUSH_TRY == *"protected branch hook declined"* ]]; then
        # create pull request for master branch, as branch is restricted
        git branch "${PR_BRANCH}"
        git checkout "${PR_BRANCH}"
        git pull origin "${PR_BRANCH}"
        git push origin "${PR_BRANCH}"
        lastCommitComment="$(git log -1 --pretty=%B)"
        hub pull-request -f -m "${lastCommitComment}" -b "${aBRANCH}" -h "${PR_BRANCH}"
    fi
    
    set -e
}

bumpVersion() {
    set -x
    echo "[info]bumping to version $1 in branch $2"

    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        cd che-parent
        git checkout $2
        #install previous version, in case it is not available in central repo
        #which is needed for dependent projects
        
        mvn clean install
        mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION}
        mvn clean install
        commitChangeOrCreatePR ${CHE_VERSION} $2 "pr-${2}-to-${1}"
        cd ..
    fi

    cd che
    git checkout $2
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[${CHE_VERSION}]
    fi
    mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=$1
    sed -i -e "s#<che.dashboard.version>.*<\/che.dashboard.version>#<che.dashboard.version>$1<\/che.dashboard.version>#" pom.xml
    sed -i -e "s#<che.version>.*<\/che.version>#<che.version>$1<\/che.version>#" pom.xml
    cd typescript-dto
        sed -i -e "s#<che.version>.*<\/che.version>#<che.version>${1}<\/che.version>#" dto-pom.xml
        sed -i -e "s#<version>.*<\/version>#<version>${1}<\/version>#" dto-pom.xml
    cd ..

    commitChangeOrCreatePR $1 $2 "pr-${2}-to-${1}"
    cd ..    
}

updateImageTagsInCheServer() {
    cd che
    git checkout ${BRANCH}
    cd .ci
    ./set_tag_version_images_linux.sh ${CHE_VERSION}
    cd ..
    git commit -asm "Set ${CHE_VERSION} release image tags"
    git push origin ${BRANCH}
}

prepareRelease() {
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        cd che-parent
        #install previous version, in case it is not available in central repo
        #which is needed for dependent projects
        mvn clean install
        mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION}
        mvn clean install
        cd ..
    fi
    echo "[INFO] Che Parent version has been updated"

    cd che
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=false -DparentVersion=[${CHE_VERSION}]
    fi
    mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=false -DnewVersion=${CHE_VERSION}
    echo "[INFO] Che Server version has been updated"

    # Replace dependencies in che-server parent
    sed -i -e "s#<che.dashboard.version>.*<\/che.dashboard.version>#<che.dashboard.version>${CHE_VERSION}<\/che.dashboard.version>#" pom.xml
    sed -i -e "s#<che.version>.*<\/che.version>#<che.version>${CHE_VERSION}<\/che.version>#" pom.xml
    echo "[INFO] Dependencies updated in che-server parent"

    cd typescript-dto
        sed -i -e "s#<che.version>.*<\/che.version>#<che.version>${CHE_VERSION}<\/che.version>#" dto-pom.xml
        # do not change the version of the parent pom, which if fixed
        sed -i -e "/<version>7.15.0<\/version>/ ! s#<version>.*<\/version>#<version>${CHE_VERSION}<\/version>#" dto-pom.xml
        echo "[INFO] Dependencies updated in che typescript DTO"
    cd ..

    # TODO more elegant way to execute these scripts
    cd .ci
    ./set_tag_version_images_linux.sh ${CHE_VERSION}
    echo "[INFO] Tag versions of images have been set in che-server"

    cd ../..
}

bumpVersions() {
    # infer project version + commit change into ${BASEBRANCH} branch
    echo "${BASEBRANCH} ${BRANCH}"
    if [[ "${BASEBRANCH}" != "${BRANCH}" ]]; then
        # bump the y digit
        [[ ${BRANCH} =~ ^([0-9]+)\.([0-9]+)\.x ]] && BASE=${BASH_REMATCH[1]}; NEXT=${BASH_REMATCH[2]}; (( NEXT=NEXT+1 )) # for BRANCH=7.10.x, get BASE=7, NEXT=11
        NEXTVERSION_Y="${BASE}.${NEXT}.0-SNAPSHOT"
        bumpVersion ${NEXTVERSION_Y} ${BASEBRANCH}
    fi
    # bump the z digit
    [[ ${CHE_VERSION} =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] && BASE="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; NEXT="${BASH_REMATCH[3]}"; (( NEXT=NEXT+1 )) # for VERSION=7.7.1, get BASE=7.7, NEXT=2
    NEXTVERSION_Z="${BASE}.${NEXT}-SNAPSHOT"
    bumpVersion ${NEXTVERSION_Z} ${BRANCH}
}

releaseOperator() {
    curl https://api.github.com/repos/eclipse/che-operator/actions/workflows/3593082/dispatches -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" -d "{\"ref\":\"master\",\"inputs\": {\"version\":\"${CHE_VERSION}\"} }"
}

loadJenkinsVars
loadMvnSettingsGpgKey
installDeps
setupGitconfig

evaluateCheVariables

set -e

loginQuay

# #release che-theia, machine-exec and devfile-registry
#  { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-theia            devtools-che-theia-che-release        90 & }; pid_1=$!;
#  { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-machine-exec     devtools-che-machine-exec-release     60 & }; pid_2=$!;
#  { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-devfile-registry devtools-che-devfile-registry-release 75 & }; pid_3=$!;
# wait
# # then release plugin-registry (depends on che-theia and machine-exec)

verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-machine-exec:${CHE_VERSION} 5
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-devfile-registry:${CHE_VERSION} 5
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia-dev:${CHE_VERSION} 5
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia:${CHE_VERSION} 5
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia-endpoint-runtime-binary:${CHE_VERSION} 5

#  { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-plugin-registry  devtools-che-plugin-registry-release  45 & }; pid_4=$!;
# wait

verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-plugin-registry:${CHE_VERSION} 5

releaseDashboard
releaseWorkspaceLoader

verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-dashboard:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-workspace-loader:${CHE_VERSION} 30

# release of che should start only when all necessary release images are available on Quay
checkoutProjects
prepareRelease
createTags

releaseCheDocs &
releaseCheServer

buildImages  ${CHE_VERSION}
tagLatestImages ${CHE_VERSION}
pushImagesOnQuay ${CHE_VERSION} pushLatest

bumpVersions
updateImageTagsInCheServer

verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-server:${CHE_VERSION} 5

releaseOperator
