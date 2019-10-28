#!/bin/bash

# This code is part of Qiskit.
#
# (C) Copyright IBM 2018, 2019.
#
# This code is licensed under the Apache License, Version 2.0. You may
# obtain a copy of this license in the LICENSE.txt file in the root directory
# of this source tree or at http://www.apache.org/licenses/LICENSE-2.0.
#
# Any modifications or derivative works of this code must retain this
# copyright notice, and modified files need to carry a notice indicating
# that they have been altered from the originals.

# Script for pushing the documentation to the qiskit.org repository.

# Non-travis variables used by this script.
TARGET_REPOSITORY="git@github.com:Qiskit/qiskit.org.git"
SOURCE_DOC_DIR="docs/_build/html"
SOURCE_DIR=`pwd`
SOURCE_LANG='en'

SOURCE_REPOSITORY="git@github.com:Qiskit/qiskit.git"
TARGET_BRANCH_PO="poBranch"
DOC_DIR_PO="docs/locale"

curl https://downloads.rclone.org/rclone-current-linux-amd64.deb -o rclone.deb
sudo apt-get install -y ./rclone.deb

RCLONE_CONFIG_PATH=$(rclone config file | tail -1)

build_old_versions () {
    pushd $SOURCE_DIR
    rclone mkdir IBMCOS:qiskit-org-website/documentation/stable

    if [[ ! -z $TRAVIS_TAG ]] ; then
        echo "Starting upload of docs for $TRAVIS_TAG"
        rclone mkdir IBMCOS:qiskit-org-website/documentation/stable/$TRAVIS_TAG
        rclone sync ./docs/_build/html IBMCOS:qiskit-org-website/documentation/stable/$TRAVIS_TAG
        echo "Finished upload of docs for $TRAVIS_TAG"
        echo "Starting copy of qiskit.org/documentation/locale/ to documentation/stable/$TRAVIS_TAG/locale"
        rclone copyto IBMCOS:qiskit-org-website/documentation/locale IBMCOS:qiskit-org-website/documentation/stable/$TRAVIS_TAG/locale
        echo "Finished copy of translated docs for $TRAVIS_TAG"
    else
        # Build stable docs
        for version in $(git tag --sort=-creatordate) ; do
            if [[ $version == "0.7*" ]] ; then
                continue
            fi

            if [[ $(rclone lsd IBMCOS:qiskit-org-website/documentation/stable | grep -c "$version") > 0 ]] ; then
                continue
            fi
            echo "Building docs for $version"
            git checkout $version
            virtualenv $version
            $version/bin/pip install .
            $version/bin/pip install -r requirements-dev.txt
            rm -rf $SOURCE_DIR/$SOURCE_DOC_DIR
            $version/bin/sphinx-build -b html docs docs/_build/html
            echo "Starting upload of docs for $version"
            rclone mkdir IBMCOS:qiskit-org-website/documentation/stable/$version
            rclone sync ./docs/_build/html IBMCOS:qiskit-org-website/documentation/stable/$version
            echo "Ending upload of docs for $version"
        done
    fi
    popd
}

# Build the documentation.
tox -edocs

echo "show current dir: "
pwd

pushd docs

# Extract document's translatable messages into pot files
# https://sphinx-intl.readthedocs.io/en/master/quickstart.html
echo "Extract document's translatable messages into pot files and generate po files"
tox -egettext -- -D language=$SOURCE_LANG

echo "Setup ssh keys"
pwd
set -e
# Add poBranch push key to ssh-agent
openssl enc -aes-256-cbc -d -in ../tools/github_poBranch_update_key.enc -out github_poBranch_deploy_key -K $encrypted_deploy_po_branch_key -iv $encrypted_deploy_po_branch_iv
chmod 600 github_poBranch_deploy_key
eval $(ssh-agent -s)
ssh-add github_poBranch_deploy_key

# Clone to the working repository for .po and pot files
popd
pwd
echo "git clone for working repo"
git clone --depth 1 $SOURCE_REPOSITORY temp --single-branch --branch $TARGET_BRANCH_PO
pushd temp
git branch
git config user.name "Qiskit Autodeploy"
git config user.email "qiskit@qiskit.org"

echo "git rm -rf for the translation po files"
git rm -rf --ignore-unmatch $DOC_DIR_PO/$SOURCE_LANG/LC_MESSAGES/*.po \
	$DOC_DIR_PO/$SOURCE_LANG/LC_MESSAGES/api \
	$DOC_DIR_PO/$SOURCE_LANG/LC_MESSAGES/apidoc \
	$DOC_DIR_PO/$SOURCE_LANG/LC_MESSAGES/_*
	
# Remove api/ and apidoc/ to avoid confusion while translating
rm -rf $SOURCE_DIR/$DOC_DIR_PO/en/LC_MESSAGES/api/ \
	$SOURCE_DIR/$DOC_DIR_PO/en/LC_MESSAGES/apidoc/ \
	$SOURCE_DIR/$DOC_DIR_PO/en/LC_MESSAGES/stubs/

# Copy the new rendered files and add them to the commit.
echo "copy directory"
cp -r $SOURCE_DIR/$DOC_DIR_PO/ docs/

# git checkout translationDocs
echo "add to po files to target dir"
git add $DOC_DIR_PO

# Commit and push the changes.
git commit -m "Automated documentation update to add .po files from meta-qiskit" -m "Commit: $TRAVIS_COMMIT" -m "Travis build: https://travis-ci.com/$TRAVIS_REPO_SLUG/builds/$TRAVIS_BUILD_ID"
echo "git push"
git push --quiet origin $TARGET_BRANCH_PO
echo "********** End of pushing po to working repo! *************"
popd

# Push to qiskit.org website
openssl aes-256-cbc -K $encrypted_rclone_key -iv $encrypted_rclone_iv -in tools/rclone.conf.enc -out $RCLONE_CONFIG_PATH -d

build_old_versions

echo "Pushing built docs to website"
rclone sync --exclude 'locale/**' --exclude 'stable/**' ./docs/_build/html IBMCOS:qiskit-org-website/documentation
