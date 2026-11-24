cd /home/user/gates/stepbase
printf '%s\n'  landed firstmatch devicerule departing union reshow rest steplog steplog2 namedbase lostused entryheads | xargs -P 3 -I{} bash /home/user/gates/stepbase/runb.sh mut2-{} mut2_{}
echo MUTEND > /home/user/gates/stepbase/mut2.done
