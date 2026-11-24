G=/home/user/gates/stepbase
cd $G
printf '%s\n' landed firstmatch devicerule departing union forkheads rest steplog namedbase | xargs -P 2 -I{} bash $G/runa.sh mut-{} mut_{}
echo MUTEND > $G/mut.done
