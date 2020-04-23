load_jenkins_vars() {
    set +x
    eval "$(./env-toolkit load -f jenkins-env.json \
                              CHE_BOT_GITHUB_TOKEN \
                              CHE_MAVEN_SETTINGS \
                              CHE_GITHUB_SSH_KEY \
                              CHE_OSS_SONATYPE_GPG_KEY \
                              CHE_OSS_SONATYPE_PASSPHRASE \
                              QUAY_ECLIPSE_CHE_USERNAME \
                              QUAY_ECLIPSE_CHE_PASSWORD)"
}

load_mvn_settings_gpg_key() {
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

install_deps(){
    set +x
    yum -y update
    yum -y install centos-release-scl-rh java-1.8.0-openjdk-devel git skopeo jq
    yum -y install rh-maven33
    yum install -y yum-utils device-mapper-persistent-data lvm2
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    curl -sL https://rpm.nodesource.com/setup_10.x | bash -
    yum-config-manager --add-repo https://dl.yarnpkg.com/rpm/yarn.repo
    yum install -y docker-ce nodejs yarn gcc-c++ make
    service docker start
}

evaluate_che_variables() {
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
}

build_and_deploy_artifacts() {
    set -x
    cd che-parent
    scl enable rh-maven33 'mvn clean install -U -Pcodenvy-release -DskipTests=true -Dskip-validate-sources'
    if [ $? -eq 0 ]; then
        echo 'Build Success!'
        echo 'Going to deploy artifacts'
        scl enable rh-maven33 "mvn clean deploy -Pcodenvy-release -DcreateChecksum=true  -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE"

    else
        echo 'Build Failed!'
        exit 1
    fi
}

# TODO ensure usage of respective bugfix branches
checkout_projects() {
    pwd
    checkout_project git@github.com:eclipse/che-parent
    checkout_project git@github.com:eclipse/che-docs
    checkout_project git@github.com:eclipse/che
    checkout_project git@github.com:eclipse/che-dashboard
    checkout_project git@github.com:eclipse/che-workspace-loader
}

checkout_project() {
    PROJECT="${1##*/}"
    echo "checking out project $PROJECT with ${BRANCH} branch"

    git clone $1
    cd $PROJECT
    git checkout ${BASEBRANCH}

    set -x
    if [[ "${BASEBRANCH}" != "${BRANCH}" ]]; then
        git branch "${BRANCH}" || git checkout "${BRANCH}" && git pull origin "${BRANCH}"
        git push origin "${BRANCH}"
        git fetch origin "${BRANCH}:${BRANCH}"
        git checkout "${BRANCH}"
    fi
    cd ..

}

# ensure proper version is used
apply_transformations() {
    #TODO here che-parent is used to aggregate all the modules under "codenvy-release" profile
    # this sed should be unhardcoded (or commited to che-parent) ASAP!
    sed -i '1677i \ \ \ \ \ \ \ \ \ \ \ \ </modules>' che-parent/pom.xml
    sed -i '1677i \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ <module>../che</module>' che-parent/pom.xml
    sed -i '1677i \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ <module>../che-workspace-loader</module>' che-parent/pom.xml
    sed -i '1677i \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ <module>../che-dashboard</module>' che-parent/pom.xml
    sed -i '1677i \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ <module>../che-docs</module>' che-parent/pom.xml
    sed -i '1677i \ \ \ \ \ \ \ \ \ \ \ \ <modules>' che-parent/pom.xml

    echo "[INFO] parent pom has been expanded with modules for release profile"

    sed -i "/<\/parent>/i \ \ \ \ \ \ \ \ <relativePath>../che-parent/dependencies</relativePath>" che-dashboard/pom.xml che-docs/pom.xml che-workspace-loader/pom.xml che/pom.xml
    echo "[INFO] relative path to parent pom has been set"

    cd che-parent
    scl enable rh-maven33 "mvn versions:set -Pcodenvy-release -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION}"
    #mvn versions:set -DgenerateBackupPoms=false -Pcodenvy-release -DnewVersion=${CHE_VERSION} #for local use
    cd ..

    echo "[INFO] version has been updated"

    #TODO more elegant way to execute these scripts
    cd che/.ci
    ./set_tag_version_images_linux.sh ${CHE_VERSION}
    echo "[INFO] tag versions of images have been set in che-server"

    # Replace dependencies in che-server parent
    cd ..
    sed -i -e "s#${VERSION}-SNAPSHOT#${NEXTVERSION}#" pom.xml
    cd ..
    echo "[INFO] dependencies updated in che-server parent"
}

# TODO change it to someone else?
setup_gitconfig() {
  git config --global user.name "Mykhailo Kuznietsov"
  git config --global user.email mkuznets@redhat.com
}

create_tags() {
    tag_and_commit che-parent
    tag_and_commit che-docs
    tag_and_commit che-dashboard
    tag_and_commit che-workspace-loader
    tag_and_commit che
}

tag_and_commit() {
    cd $1
    git commit -asm "Release version ${CHE_VERSION}"
    if [ $(git tag -l "$CHE_VERSION") ]; then
        echo "tag ${CHE_VERSION} already exists! recreating ..."
        git tag "${CHE_VERSION}"
    else
        echo "[INFO] creating new tag ${CHE_VERSION}"
        git push origin :${CHE_VERSION}
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
         bash $(pwd)/${image_dir}/build.sh --tag:${TAG} 
         if [[ ${image_dir} == "che/dockerfiles/che" ]]; then
           #CENTOS SINGLE USER
           BUILD_ASSEMBLY_DIR=$(echo assembly/assembly-main/target/eclipse-che-*/eclipse-che-*/)
           LOCAL_ASSEMBLY_DIR="${image_dir}/eclipse-che"
           if [[ -d "${LOCAL_ASSEMBLY_DIR}" ]]; then
               rm -r "${LOCAL_ASSEMBLY_DIR}"
           fi
           cp -r "${BUILD_ASSEMBLY_DIR}" "${LOCAL_ASSEMBLY_DIR}"
           docker build -t ${REGISTRY}/${ORGANIZATION}/che-server:${TAG}-centos -f $(pwd)/${image_dir}/Dockerfile.centos $(pwd)/${image_dir}/
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
         if [[ ${image} == "${REGISTRY}/${ORGANIZATION}/che-server" ]]; then
           docker tag "${image}:$1-centos" "${image}:latest-centos"
         fi
         if [[ $? -ne 0 ]]; then
           die_with  "docker tag of '${image}' image is failed!"
         fi
     done
}

pushImagesOnQuay() {
    #PUSH IMAGES
      if [[ -n "${QUAY_ECLIPSE_CHE_USERNAME}" ]] && [[ -n "${QUAY_ECLIPSE_CHE_PASSWORD}" ]]; then
        docker login -u "${QUAY_ECLIPSE_CHE_USERNAME}" -p "${QUAY_ECLIPSE_CHE_PASSWORD}" "${REGISTRY}"
    else
        echo "Could not login, missing credentials for pushing to the '${ORGANIZATION}' organization"
         return
    fi
    for image in ${IMAGES_LIST[@]}
        do
            echo y | docker push "${image}:$1"
            if [[ $2 == "pushLatest" ]]; then
                echo y | docker push "${image}:latest"
            fi
            if [[ ${image} == "${REGISTRY}/${ORGANIZATION}/che-server" ]]; then
                if [[ $2 == "pushLatest" ]]; then
                echo y | docker push "${REGISTRY}/${ORGANIZATION}/che-server:latest-centos"
                fi
            echo y | docker push "${REGISTRY}/${ORGANIZATION}/che-server:$1-centos"
            fi
            if [[ $? -ne 0 ]]; then
            die_with  "docker push of '${image}' image is failed!"
            fi
        done
}

load_jenkins_vars
load_mvn_settings_gpg_key
install_deps
setup_gitconfig

evaluate_che_variables

# release che-theia, machine-exec, plugin-registry and devfile-registry
#./cico_release_theia_and_registries.sh

# release of che should start only when all necessary release images are available on Quay
checkout_projects
apply_transformations
create_tags

build_and_deploy_artifacts
buildImages  ${CHE_VERSION}
tagLatestImages ${CHE_VERSION}
pushImagesOnQuay ${CHE_VERSION} pushLatest