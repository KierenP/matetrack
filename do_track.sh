#!/bin/bash

# exit on errors
set -e

if [ $# -eq 0 ]
  then
    echo "Please specify syzygyPath"
    exit 1
fi

echo "started at: " $(date)

start=e08e16f959d8d7cbf0980c01c3a05dd225dc4bfc
firstrev=$start
lastrev=HEAD
exclude=exclude_commits.sha
syzygyPath=$1

# the repo uses 1M nodes for each position
nodes=1000000

# check if we run with the repo values
[ "$firstrev" = "$start" ] && [ "$lastrev" = "HEAD" ] && [ "$nodes" = "1000000" ] && repo=yes || repo=no

# clone as needed
if [[ ! -e Halogen ]]; then
    git clone https://github.com/KierenP/Halogen.git
fi

# update and get a sorted revision list and all the release tags
cd Halogen/src
git checkout master >&checkout.log
git fetch origin >&fetch.log
git pull >&pull.log
revs=$(git rev-list --reverse $firstrev^..$lastrev)
tags=$(git ls-remote --quiet --tags | grep -E "v[0-9]+(\.[0-9]+)?")
cd ../..

# use compact file names for the repo
if [ "$repo" = "yes" ]; then
    csv=matetrack$nodes.csv # list of previously computed results
    new=new$nodes.csv       # temporary list of newly computed results
else
    csv=matetrack_"$firstrev"_"$lastrev"_"$nodes".csv
    new=new_"$firstrev"_"$lastrev"_"$nodes".csv
fi
out=out.tmp # file for output from matecheck.py

# if necessary, create a new csv file with the correct header
if [[ ! -f $csv ]]; then
    echo "Commit Date,Commit SHA,Positions,Mates,Best mates,Better mates,Wrong mates,Bad PVs,Release tag" >$csv
fi

# if necessary, merge results from a previous (interrupted) run of this script
if [[ -f $new ]]; then
    cat $new >>$csv && rm $new
    python3 plotdata.py $csv
fi

# go over the revision list and obtain missing results if necessary
for rev in $revs; do
    if ! grep -q "$rev" "$csv"; then
        cd Halogen/src
        git checkout $rev >&checkout2.log
        epoch=$(git show --pretty=fuller --date=iso-strict $rev | grep 'CommitDate' | awk '{print $NF}')
        tag=$(echo "$tags" | grep $rev | sed 's/.*\///' | sed 's/sf_5\^{}/sf_5/')

        # check if revision SHA is in non-comment section of exclude file
        if ! sed 's/#.*//' "../../$exclude" | grep -q "$rev"; then
            echo "running matecheck on revision $rev "

            # compile revision and get binary
            make clean >&clean.log
            arch=avx2-pext
            # fallback to 'native' for versions before avx2-pext
            if ! grep -q "$arch" Makefile; then
                arch=native
            fi
            make -j $arch EXE=../bin/Halogen.exe >&make.log
            cd ../..

            # run a matecheck round on this binary, being nice to other processes
            nproc_use=$(nproc)
            if [ $nproc_use -gt 1 ]; then
                nproc_use=$((3 * nproc_use / 4))
            fi
            nice python3 matecheck.py --engine ./Halogen/bin/Halogen.exe --nodes $nodes --concurrency $nproc_use --syzygyPath $syzygyPath >&$out

            # collect results for this revision
            total=$(grep "Total FENs:" $out | awk '{print $3}')
            mates=$(grep "Found mates:" $out | awk '{print $3}')
            bmates=$(grep "Best mates:" $out | awk '{print $3}')
            better=$(grep "Better mates:" $out | awk '{print $3}')
            wrong=$(grep "Wrong mates:" $out | awk '{print $3}')
            badpvs=$(grep "Bad PVs:" $out | awk '{print $3}')

            # save wrong/better mates and wrong or incomplete PVs for possible debugging
            if grep -q issues $out; then
                mv $out out$nodes.$rev
            fi
        else
            echo "skipping non-viable revision $rev "
            cd ../..
            total= mates= bmates= better= wrong= badpvs=
        fi
        echo "$epoch,$rev,$total,$mates,$bmates,$better,$wrong,$badpvs,$tag" >>$new
    fi
done

if [[ -f $new ]]; then
    cat $new >>$csv && rm $new
    python3 plotdata.py $csv
fi

if [ "$repo" = "yes" ]; then
    git add $csv matetrack$nodes.png matetrack"$nodes"all.png
    git diff --staged --quiet || git commit -m "Update results"
    git push origin master >&push.log
fi

echo "ended at: " $(date)
