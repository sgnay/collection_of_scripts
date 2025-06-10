#!/bin/bash
# script name: swap_statistics.sh
# Author: sgnay
# description: 统计进程使用 swap 的情况

get_swap() {
for PROC_PID in $(find /proc/ -maxdepth 1 -type d | egrep "^/proc/[0-9]") ; do
TOTAL=$(awk '{if($1=="Swap:") {sum+=$2} } END {if(sum>0) {print sum}}' ${PROC_PID}/smaps 2>/dev/null)
if [ $TOTAL ] ;then
      echo -e "$(cat ${PROC_PID}/comm)_$(basename ${PROC_PID}): $TOTAL"
  unset TOTAL
fi
done
}

create_fifo() {
TMP_FIFO=$(mktemp -u)
if [ ! -e ${TMP_FIFO} ] ; then
  mkfifo ${TMP_FIFO}
  exec 3<>${TMP_FIFO}
  rm -f ${TMP_FIFO}
else
  exit 1
fi
}

create_fifo
get_swap >&3

while read -u3 -t 1 line
do
    [[ -n $line ]] && echo $line || exec 3>&-
done | sort -t":" -nrk2
exec 3>&-
