#!/bin/sh

#####
#
# Configuration options
#
#####

# e-mail address to send results to
#results_addr=testing@lists.open-mpi.org
results_addr=rhc@open-mpi.org

# Set this to any value for additional output; typically only when
# debugging
: ${debug:=}

# svn repository uri
master_code_uri=https://github.com/pmix/master.git
master_raw_uri=https://raw.github.com/pmix/master
release_code_uri=https://github.com/pmix/releases.git
release_raw_uri=https://raw.github.com/pmix/releases

# where to put built tarballs
outputroot=$HOME/pmix/nightly

# Target where to scp the final tarballs
output_ssh_target=ompiteam@192.185.39.252

# where to find the build script
script_uri=contrib/nightly/create_tarball.sh

# helper scripts dir
script_dir=$HOME/ompi/contrib/build-server

# The tarballs to make
if [ $# -eq 0 ] ; then
    branches="master"
else
    branches=$@
fi

# Build root - scratch space
build_root=$HOME/pmix/nightly-tarball-build-root

# Coverity stuff
coverity_token=`cat $HOME/coverity/pmix-token.txt`
coverity_configure_args="--with-libevent=$HOME_PREFIX"

export PATH=$HOME_PREFIX/bin:$PATH
export LD_LIBRARY_PATH=$HOME_PREFIX/lib:$LD_LIBRARY_PATH

#####
#
# Actually do stuff
#
#####

debug() {
    if test -n "$debug"; then
        echo "=== DEBUG: $*"
    fi
}

run_command() {
    debug "Running command: $*"
    debug "Running in pwd: `pwd`"
    if test -n "$debug"; then
        eval $*
    else
        eval $* > /dev/null 2>&1
    fi

    if test $? -ne 0; then
        echo "=== Command failed: $*"
    fi
}

# load the modules configuration
. $MODULE_INIT
module use $AUTOTOOL_MODULE

# get our nightly build script
mkdir -p $build_root
cd $build_root

pending_coverity=$build_root/tarballs-to-run-through-coverity.txt
rm -f $pending_coverity
touch $pending_coverity

# Loop making the tarballs
module unload autotools
for branch in $branches; do
    echo "=== Branch: $branch"
    # Get the last tarball version that was made
    prev_snapshot=`cat $outputroot/$branch/latest_snapshot.txt`
    prev_snapshot_hash=`echo $prev_snapshot | cut -d- -f3`
    echo "=== Previous snapshot: $prev_snapshot (hash: $prev_snapshot_hash)"

    if test "$branch" = "master"; then
        code_uri=$master_code_uri
        raw_uri=$master_raw_uri
    else
        code_uri=$release_code_uri
        raw_uri=$release_raw_uri
    fi

    # Form a URL-specific script name
    script=$branch-`basename $script_uri`

    echo "=== Getting script from: $raw_uri"
    run_command wget --quiet --no-check-certificate --tries=10 $raw_uri/$branch/$script_uri -O $script
    if test ! $? -eq 0 ; then
        echo "wget of PMIX nightly tarball create script failed."
        if test -f $script ; then
            echo "Using older version of $script for this run."
        else
            echo "No build script available.  Aborting."
            exit 1
        fi
    fi
    chmod +x $script

    module load "autotools/pmix-$branch"
    # module load "libevent/pmix-$branch"

    echo "=== Running script..."
    run_command ./$script \
        $build_root/$branch \
        $results_addr \
        $outputroot/$branch \
        $code_uri \
        $branch

    module unload autotools
    echo "=== Done running script"

    # Did the script generate a new tarball?  Ensure to compare the
    # only the hash of the previous tarball and the hash of the new
    # tarball (the filename also contains the date/timestamp, which
    # will always be different).

    # If so, save it so that we can spawn the coverity checker on it
    # afterwards.  Only for this for the master (for now).
    latest_snapshot=`cat $outputroot/$branch/latest_snapshot.txt`
    latest_snapshot_hash=`echo $latest_snapshot | cut -d- -f3`
    echo "=== Latest snapshot: $latest_snapshot (hash: $latest_snapshot_hash)"
    if test "$prev_snapshot_hash" = "$latest_snapshot_hash"; then
        echo "=== Hash has not changed; no need to upload/save the new tarball"
    else
        if test "$branch" = "master"; then
            echo "=== Saving output for a Coverity run"
            echo "$outputroot/$branch/pmix-$latest_snapshot.tar.bz2" >> $pending_coverity
        else
            echo "=== NOT saving output for a Coverity run"
        fi
        echo "=== Posting tarball to open-mpi.org"
        # tell the web server to cleanup old nightly tarballs
        run_command ssh -p 2222 \
            $output_ssh_target \
            \"git/ompi/contrib/build-server/remove-old.pl 7 public_html/software/pmix/nightly/$branch\"
        # upload the new ones
        run_command scp -P 2222 \
            $outputroot/$branch/pmix-$latest_snapshot.tar.* \
            $output_ssh_target:public_html/software/pmix/nightly/$branch/
        run_command scp -P 2222 \
            $outputroot/$branch/latest_snapshot.txt \
            $output_ssh_target:public_html/software/pmix/nightly/$branch/
        # direct the web server to regenerate the checksums
        run_command ssh -p 2222 \
            $output_ssh_target \
            \"cd public_html/software/pmix/nightly/$branch \&\& md5sum pmix\* \> md5sums.txt\"
        run_command ssh -p 2222 \
            $output_ssh_target \
            \"cd public_html/software/pmix/nightly/$branch \&\& sha1sum pmix\* \> sha1sums.txt\"
    fi

    # Failed builds are not removed.  But if a human forgets to come
    # in here and clean up the old failed builds, we can accumulate
    # many over time.  So remove any old failed bbuilds that are over
    # 4 weeks old.
    run_command ${script_dir}/remove-old.pl 7 $build_root/$branch
done

# If we had any new snapshots to send to coverity, process them now

for tarball in `cat $pending_coverity`; do
    echo "=== Submitting $tarball to Coverity..."
    run_command ${script_dir}/pmix-nightly-coverity.pl \
        --filename=$tarball \
        --coverity-token=$coverity_token \
        --verbose \
        --logfile-dir=$HOME/coverity \
        --make-args=-j8 \
        --configure-args=\"$coverity_configure_args\"
done
rm -f $pending_coverity
