#!/usr/bin/env bash
# Debug option - should be disabled unless required
#set -x
#=====================================================================================================================
#   DESCRIPTION  Generating a stand alone web report for postix log files,
#                Runs on all Linux platforms with postfix installed
#   AUTHOR       Riaan Pretorius <pretorius.riaan@gmail.com>
#   IDIOCRACY    yes.. i know.. bash??? WTF was i thinking?? Well it works, runs every
#                where and it is portable
#
#   https://en.wikipedia.org/wiki/MIT_License
#
#   LICENSE
#   MIT License
#
#   Copyright (c) 2018 Riaan Pretorius
#
#   Permission is hereby granted, free of charge, to any person obtaining a copy of this software
#   and associated documentation files  (the "Software"), to deal in the Software without restriction,
#   including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
#   and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
#   subject to the following conditions:
#
#   The above copyright notice and this permission notice shall be included in all copies or substantial
#   portions of the Software.
#
#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
#   NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
#   IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
#   WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION  WITH THE SOFTWARE
#   OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#=====================================================================================================================

# VARIABLES
function showhelp {
        echo "
How to use it:
  $0 -l|--logfile <path> [-d|--date <today|yesterday*|weekly|YYYY-MM-DD>] [-h|--help]

Select any of these options:
  -l, --logfile         Mandatory, select path of the Postfix log file to analyze. Could be plain text or either a compressed gzip file (gz)
  -d, --date            Optional, could be one of the following values: today, yesterday (default) or YYYY-MM-DD formatted date
  -h, --help            Some help here!

"
}

if [[ "$#" = 0 ]]; then showhelp; exit 1; fi

function checkarg {
        if [ -z "$2" ]; then
                echo "Error: must specify parameter for $1 function"
                echo ""
                showhelp
                exit 1
        fi
        if [ "$1" == "logfile" ] && [ ! -e $2 ]; then
                echo "Path do not seem to exist. Exiting..."
                echo ""
                exit 1
        fi
        if [ "$1" == "date" ] && [[ "$2" != "today" && "$2" != "yesterday" && "$2" != "weekly" && ! "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
		echo "Error: Invalid input. Please provide 'today', 'yesterday', 'weekly', or a date in the format YYYY-MM-DD." >&2
		echo ""
		exit 1
	fi
}

while [[ "$#" > 0 ]]; do
  case "$1" in
    -l|--logfile)       checkarg "logfile" "$2" ; LOGFILE="$2" ; shift;;
    -d|--date)          checkarg "date" "$2"    ; MY_DATE="$2"    ; shift;;
    -h|--help)          HELP=true               ;;
    *|-*|--*)           showhelp                ; exit 1       ;;
  esac
  shift
done


#MANDATORY LOGFILE PARAMETER
if [[ -f "${LOGFILE}" ]]; then
    filetype=$(file --mime-type -b "${LOGFILE}")
    if [[ "${filetype}" == "application/gzip" ]]; then
	MY_CAT="$(which zcat)"
    elif [[ "${filetype}" == "text/plain" ]]; then
	MY_CAT="$(which cat)"
    else
        echo "The file '${LOGFILE}' is of an unknown type: ${filetype}"
        exit 1
    fi
else
        echo "Call script including postfix log file to be analyzed. Could be plain text or even gz file."
        echo "(Execute with --help)"
        exit 1
fi

#CONSIDER DEFAULTING DATE
[ -z ${MY_DATE} ] && MY_DATE="yesterday"

#CONFIG FILE LOCATION
MAINDIR="/home/postfix"

#CURRENT PATH OF THIS SCRIPT
MY_PATH="$(dirname -- "${BASH_SOURCE[0]}")"
MY_PATH="$(cd -- "$MY_PATH" && pwd)"

#HTML Output
HTMLOUTPUTDIR="${MAINDIR}/www"
HTMLOUTPUT_INDEXDASHBOARD="index.html"

#Create the Cache Directory if it does not exist
DATADIR="${HTMLOUTPUTDIR}/data"
if [ ! -d ${DATADIR} ]; then
  mkdir -p ${DATADIR};
fi

#TOOLS
ACTIVEHOSTNAME=$(cat /proc/sys/kernel/hostname)
MOVEF="/usr/bin/mv -f "

#FETCH LOGFILE DATE
FILE_DATE="$(stat -c "%y" ${LOGFILE})"
FILE_MONTH=$(date --date "${FILE_DATE}" +'%b')


#WEEKLY REPORT
WEEKLY=false

if [ "${MY_DATE}" == "weekly" ]
then
	WEEKLY=true
	#Pick-up last modification date of file, and extract one day (supossing it is a rotated file always)
	MY_DATE="$(date --date "${FILE_DATE} -1 days" "+%Y-%m-%d")"
fi

#Temporal Values
REPORTDATE=$(date '+%Y-%m-%d %H:%M:%S')
CURRENTYEAR=$(date  --date "${MY_DATE}" +'%Y')
CURRENTMONTH=$(date --date "${MY_DATE}" +'%b')
CURRENTDAY=$(date   --date "${MY_DATE}" +"%d")

if ${WEEKLY}
then
	CURRENTYEAR="Weekly-${CURRENTYEAR}"
fi


#Just verificate that there are some log lines for specified
if [ $(${MY_CAT} ${LOGFILE} | grep -i postfix | grep -P "^${CURRENTMONTH}\s+$(date --date "${MY_DATE}" +"%-d")" | wc -l) -eq 0 ]
then
	echo "Specified '${LOGFILE}' seems to not include loglines for specified '${MY_DATE}' date."
	echo "Aborting..."
	exit 1
fi

#RAW LOGS Output
RAWDIR="${HTMLOUTPUTDIR}/data/reports"

#Create the RAW LOGS folder always
mkdir -p ${RAWDIR};

#Link for raw log in html
RAWFILELINK="reports/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.txt"
RAWFILENAME="$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.txt"

#Temp folder
TMPFOLDER="$HTMLOUTPUTDIR/.temp"

#Create the temp Directory if it does not exist
mkdir -p ${TMPFOLDER};


#pflogsumm details
PFLOGSUMMOPTIONS=" --verbose_msg_detail --zero_fill -e "
PFLOGSUMMBIN="${MY_PATH}/pflogsumm.pl "

#output main files
FULL_REPORT="${TMPFOLDER}/mailfullreport"
DAILY_REPORT="${TMPFOLDER}/maildailyreport"

#Trigger pflogsumm for ${DATE} logs if not requesting a weekly report
if ! ${WEEKLY}
then
	#Used for everything but Per-Day Traffic Summary
	${MY_CAT} ${LOGFILE} | $PFLOGSUMMBIN $PFLOGSUMMOPTIONS -d ${MY_DATE} > ${DAILY_REPORT}
	#Trigger pflogsum for all the days the log contains, to retrieve information for the Per-Day Traffic Summary
	#but grep out exceeded dated lines from log (considering there are going to be few lines from the date the rotated log was created)
	${MY_CAT} ${LOGFILE} | grep -v -P "^${FILE_MONTH}\s+$(date --date "${FILE_DATE}" +"%-d")" | $PFLOGSUMMBIN $PFLOGSUMMOPTIONS > ${FULL_REPORT}
fi

#If weekly report is requested, just make one report and make output variables equal
if ${WEEKLY}
then
	#Full report but grep out exceeded dated lines from log (considering there are going to be few lines from the date the rotated log was created)
	${MY_CAT} ${LOGFILE} | grep -v -P "^${CURRENTMONTH}\s+$(date --date "${MY_DATE} + 1 days" +"%-d")" | $PFLOGSUMMBIN $PFLOGSUMMOPTIONS > ${FULL_REPORT}
	DAILY_REPORT=${FULL_REPORT}
fi


#Extract from last days PFLOGSUMM
sed -n '/^Per-Day Traffic Summary/,/^Per-Hour/p;/^Per-Hour/q' ${FULL_REPORT} | sed -e '1,4d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D'  > ${TMPFOLDER}/PerDayTrafficSummary

#Extract from today PFLOGSUMM
sed -n -r '/^Grand Totals/,/^(Per-Hour|Per-Day)/p;/^(Per-Hour|Per-Day)/q' ${DAILY_REPORT} | sed -e '1,4d' | sed -e :a -e '$d;N;2,3ba' -e 'P;D' | sed '/^$/d' > ${TMPFOLDER}/GrandTotals
sed -n -r '/^(Per-Hour Traffic Summary|Per-Hour Traffic Daily Average)/,/^Host\//p;/^Host\//q' ${DAILY_REPORT} | sed -e '1,4d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D'  > ${TMPFOLDER}/PerHourTrafficSummary
sed -n '/^Host\/Domain Summary\: Message Delivery/,/^Host\/Domain Summary\: Messages Received/p;/^Host\/Domain Summary\: Messages Received/q' ${DAILY_REPORT} | sed -e '1,4d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D'  > ${TMPFOLDER}/HostDomainSummaryMessageDelivery
sed -n '/^Host\/Domain Summary\: Messages Received/,/^Remote Domains by message count/p;/^Remote Domains by message count/q' ${DAILY_REPORT} | sed -e '1,4d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D'  > ${TMPFOLDER}/HostDomainSummaryMessagesReceived

sed -n '/^Remote Domains by message count/,/^Remote Recipients by message count/p;/^Remote Recipients by message count/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d'  > ${TMPFOLDER}/RemoteDomains
sed -n '/^Remote Recipients by message count/,/^Local Domains by message count/p;/^Local Domains by message count/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d'  > ${TMPFOLDER}/RemoteRecipients
sed -n '/^Local Domains by message count/,/^Local Recipients by message count/p;/^Local Recipients by message count/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d'  > ${TMPFOLDER}/LocalDomains
sed -n '/^Local Recipients by message count/,/^Senders by message count/p;/^Senders by message count/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d'  > ${TMPFOLDER}/LocalRecipients

sed -n '/^Senders by message count/,/^Recipients by message count/p;/^Recipients by message count/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d' > ${TMPFOLDER}/Sendersbymessagecount
sed -n '/^Recipients by message count/,/^Senders by message size/p;/^Senders by message size/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d' > ${TMPFOLDER}/Recipientsbymessagecount
sed -n '/^Senders by message size/,/^Recipients by message size/p;/^Recipients by message size/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d' > ${TMPFOLDER}/Sendersbymessagesize
sed -n -r '/^Recipients by message size/,/^(Messages with no size data|message deferral detail)/p;/^(Messages with no size data|message deferral detail)/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d' > ${TMPFOLDER}/Recipientsbymessagesize
sed -n '/^Messages with no size data/,/^message deferral detail/p;/^message deferral detail/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d' > ${TMPFOLDER}/Messageswithnosizedata
sed -n '/^message deferral detail/,/^message bounce detail (by relay)/p;/^message bounce detail (by relay)/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d' > ${TMPFOLDER}/messagedeferraldetail
sed -n '/^message bounce detail (by relay)/,/^message reject detail/p;/^message reject detail/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d' > ${TMPFOLDER}/messagebouncedetaibyrelay
sed -n '/^Warnings/,/^Fatal Errors/p;/^Fatal Errors/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d' > ${TMPFOLDER}/warnings

sed -n '/^Fatal Errors/,/^Master daemon messages/p;/^Master daemon messages/q' ${DAILY_REPORT} | sed -e '1,2d' | sed -e :a -e '$d;N;2,2ba' -e 'P;D' | sed '/^$/d' > ${TMPFOLDER}/FatalErrors


#======================================================
# Extract Information into variables -> Grand Totals
#======================================================
ReceivedEmail=$(awk '$2=="received" {print $1}'  ${TMPFOLDER}/GrandTotals)
DeliveredEmail=$(awk '$2=="delivered" {print $1}'  ${TMPFOLDER}/GrandTotals)
DeliveredEmailRemote=$(sed 's/remote delivered/remotedelivered/' ${TMPFOLDER}/GrandTotals | awk '$2=="remotedelivered" {print $1}')
DeliveredEmailRemotePercentage=$(sed 's/remote delivered/remotedelivered/' ${TMPFOLDER}/GrandTotals | awk '$2=="remotedelivered" {print $3}')
DeliveredEmailLocal=$(sed 's/local delivered/localdelivered/' ${TMPFOLDER}/GrandTotals | awk '$2=="localdelivered" {print $1}')
DeliveredEmailLocalPercentage=$(sed 's/local delivered/localdelivered/' ${TMPFOLDER}/GrandTotals | awk '$2=="localdelivered" {print $3}')
ForwardedEmail=$(awk '$2=="forwarded" {print $1}'  ${TMPFOLDER}/GrandTotals)
DeferredEmailCount=$(awk '$2=="deferred" {print $1}'  ${TMPFOLDER}/GrandTotals)
DeferredEmailDeferralsCount=$(awk '$2=="deferred" {print $3" "$4}'  ${TMPFOLDER}/GrandTotals)
BouncedEmail=$(awk '$2=="bounced" {print $1}'  ${TMPFOLDER}/GrandTotals)
RejectedEmailCount=$(awk '$2=="rejected" {print $1}'  ${TMPFOLDER}/GrandTotals)
RejectedEmailPercentage=$(awk '$2=="rejected" {print $3}'  ${TMPFOLDER}/GrandTotals)
RejectedWarningsEmail=$(sed 's/reject warnings/rejectwarnings/' ${TMPFOLDER}/GrandTotals | awk '$2=="rejectwarnings" {print $1}')
HeldEmail=$(awk '$2=="held" {print $1}'  ${TMPFOLDER}/GrandTotals)
DiscardedEmailCount=$(awk '$2=="discarded" {print $1}'  ${TMPFOLDER}/GrandTotals)
DiscardedEmailPercentage=$(awk '$2=="discarded" {print $3}'  ${TMPFOLDER}/GrandTotals)
BytesReceivedEmail=$(sed 's/bytes received/bytesreceived/' ${TMPFOLDER}/GrandTotals | awk '$2=="bytesreceived" {print $1}'|sed 's/[^0-9]*//g' )
BytesDeliveredEmail=$(sed 's/bytes delivered/bytesdelivered/' ${TMPFOLDER}/GrandTotals | awk '$2=="bytesdelivered" {print $1}'|sed 's/[^0-9]*//g')
SendersEmail=$(awk '$2=="senders" {print $1}'  ${TMPFOLDER}/GrandTotals)
SendingHostsDomainsEmail=$(sed 's/sending hosts\/domains/sendinghostsdomains/' ${TMPFOLDER}/GrandTotals | awk '$2=="sendinghostsdomains" {print $1}')
RecipientsEmail=$(awk '$2=="recipients" {print $1}'  ${TMPFOLDER}/GrandTotals)
RecipientHostsDomainsEmail=$(sed 's/recipient hosts\/domains/recipienthostsdomains/' ${TMPFOLDER}/GrandTotals | awk '$2=="recipienthostsdomains" {print $1}')


#======================================================
# Extract Information into variable -> Per-Day Traffic Summary
#======================================================
while IFS= read -r var
do
    PerDayTrafficSummaryTable=""
    PerDayTrafficSummaryTable+="<tr>"
    PerDayTrafficSummaryTable+=$(echo "$var" | awk '{print "<td>"$1" "$2" "$3"</td>""<td>"$4"</td>""<td>"$5"</td>""<td>"$6"</td>""<td>"$7"</td>""<td>"$8"</td>"}')
    PerDayTrafficSummaryTable+="</tr>"
    echo $PerDayTrafficSummaryTable >> ${TMPFOLDER}/PerDayTrafficSummary_tmp
done < ${TMPFOLDER}/PerDayTrafficSummary
$MOVEF  ${TMPFOLDER}/PerDayTrafficSummary_tmp ${TMPFOLDER}/PerDayTrafficSummary &> /dev/null

#======================================================
# Extract Information into variable -> Per-Hour Traffic Summary
#======================================================
while IFS= read -r var
do
    PerHourTrafficSummaryTable=""
    PerHourTrafficSummaryTable+="<tr>"
    PerHourTrafficSummaryTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>""<td>"$3"</td>""<td>"$4"</td>""<td>"$5"</td>""<td>"$6"</td>"}')
    PerHourTrafficSummaryTable+="</tr>"
    echo $PerHourTrafficSummaryTable >> ${TMPFOLDER}/PerHourTrafficSummary_tmp
done < ${TMPFOLDER}/PerHourTrafficSummary
$MOVEF ${TMPFOLDER}/PerHourTrafficSummary_tmp ${TMPFOLDER}/PerHourTrafficSummary &> /dev/null


#======================================================
# Extract Information into variable -> Host Domain Summary Messages Delivery
#======================================================
while IFS= read -r var
do
    HostDomainSummaryMessageDeliveryTable=""
    HostDomainSummaryMessageDeliveryTable+="<tr>"
    HostDomainSummaryMessageDeliveryTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>""<td>"$3"</td>""<td>"$4" "$5"</td>""<td>"$6" "$7"</td>""<td>"$8"</td>" }')
    HostDomainSummaryMessageDeliveryTable+="</tr>"
    echo $HostDomainSummaryMessageDeliveryTable >> ${TMPFOLDER}/HostDomainSummaryMessageDelivery_tmp
done < ${TMPFOLDER}/HostDomainSummaryMessageDelivery
$MOVEF ${TMPFOLDER}/HostDomainSummaryMessageDelivery_tmp ${TMPFOLDER}/HostDomainSummaryMessageDelivery &> /dev/null


#======================================================
# Extract Information into variable -> Host Domain Summary Messages Received
#======================================================
while IFS= read -r var
do
    HostDomainSummaryMessagesReceivedTable=""
    HostDomainSummaryMessagesReceivedTable+="<tr>"
    HostDomainSummaryMessagesReceivedTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>""<td>"$3"</td>"}')
    HostDomainSummaryMessagesReceivedTable+="</tr>"
    echo $HostDomainSummaryMessagesReceivedTable >> ${TMPFOLDER}/HostDomainSummaryMessagesReceived_tmp
done < ${TMPFOLDER}/HostDomainSummaryMessagesReceived
$MOVEF ${TMPFOLDER}/HostDomainSummaryMessagesReceived_tmp ${TMPFOLDER}/HostDomainSummaryMessagesReceived &> /dev/null

#======================================================
# Extract Information into variable -> Remote Domains
#======================================================
while IFS= read -r var
do
    RemoteDomainscountTable=""
    RemoteDomainscountTable+="<tr>"
    RemoteDomainscountTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>"}')
    RemoteDomainscountTable+="</tr>"
    echo $RemoteDomainscountTable >> ${TMPFOLDER}/RemoteDomains_tmp
done < ${TMPFOLDER}/RemoteDomains
$MOVEF  ${TMPFOLDER}/RemoteDomains_tmp ${TMPFOLDER}/RemoteDomains &> /dev/null


#======================================================
# Extract Information into variable -> Remote Recipients
#======================================================
while IFS= read -r var
do
    RemoteRecipientscountTable=""
    RemoteRecipientscountTable+="<tr>"
    RemoteRecipientscountTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>"}')
    RemoteRecipientscountTable+="</tr>"
    echo $RemoteRecipientscountTable >> ${TMPFOLDER}/RemoteRecipients_tmp
done < ${TMPFOLDER}/RemoteRecipients
$MOVEF  ${TMPFOLDER}/RemoteRecipients_tmp ${TMPFOLDER}/RemoteRecipients &> /dev/null


#======================================================
# Extract Information into variable -> Local Domains
#======================================================
while IFS= read -r var
do
    LocalDomainscountTable=""
    LocalDomainscountTable+="<tr>"
    LocalDomainscountTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>"}')
    LocalDomainscountTable+="</tr>"
    echo $LocalDomainscountTable >> ${TMPFOLDER}/LocalDomains_tmp
done < ${TMPFOLDER}/LocalDomains
$MOVEF  ${TMPFOLDER}/LocalDomains_tmp ${TMPFOLDER}/LocalDomains &> /dev/null


#======================================================
# Extract Information into variable -> Local Recipients
#======================================================
while IFS= read -r var
do
    LocalRecipientscountTable=""
    LocalRecipientscountTable+="<tr>"
    LocalRecipientscountTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>"}')
    LocalRecipientscountTable+="</tr>"
    echo $LocalRecipientscountTable >> ${TMPFOLDER}/LocalRecipients_tmp
done < ${TMPFOLDER}/LocalRecipients
$MOVEF  ${TMPFOLDER}/LocalRecipients_tmp ${TMPFOLDER}/LocalRecipients &> /dev/null


#======================================================
# Extract Information into variable -> Host Domain Summary Messages Received
#======================================================
while IFS= read -r var
do
    SendersbymessagecountTable=""
    SendersbymessagecountTable+="<tr>"
    SendersbymessagecountTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>"}')
    SendersbymessagecountTable+="</tr>"
    echo $SendersbymessagecountTable >> ${TMPFOLDER}/Sendersbymessagecount_tmp
done < ${TMPFOLDER}/Sendersbymessagecount
$MOVEF  ${TMPFOLDER}/Sendersbymessagecount_tmp ${TMPFOLDER}/Sendersbymessagecount &> /dev/null

#======================================================
# Extract Information into variable -> Recipients by message count
#======================================================
 while IFS= read -r var
do
    RecipientsbymessagecountTable=""
    RecipientsbymessagecountTable+="<tr>"
    RecipientsbymessagecountTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>"}')
    RecipientsbymessagecountTable+="</tr>"
    echo $RecipientsbymessagecountTable >> ${TMPFOLDER}/Recipientsbymessagecount_tmp
done < ${TMPFOLDER}/Recipientsbymessagecount
$MOVEF ${TMPFOLDER}/Recipientsbymessagecount_tmp ${TMPFOLDER}/Recipientsbymessagecount &> /dev/null


#======================================================
# Extract Information into variable -> Senders by message size
#======================================================
 while IFS= read -r var
do
    SendersbymessagesizeTable=""
    SendersbymessagesizeTable+="<tr>"
    SendersbymessagesizeTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>"}')
    SendersbymessagesizeTable+="</tr>"
    echo $SendersbymessagesizeTable >> ${TMPFOLDER}/Sendersbymessagesize_tmp
done < ${TMPFOLDER}/Sendersbymessagesize
$MOVEF ${TMPFOLDER}/Sendersbymessagesize_tmp ${TMPFOLDER}/Sendersbymessagesize &> /dev/null


#======================================================
# Extract Information into variable -> Recipients by messagesize Table
#======================================================
while IFS= read -r var
do
    RecipientsbymessagesizeTable=""
    RecipientsbymessagesizeTable+="<tr>"
    RecipientsbymessagesizeTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>"}')
    RecipientsbymessagesizeTable+="</tr>"
    echo $RecipientsbymessagesizeTable >> ${TMPFOLDER}/Recipientsbymessagesize_tmp
done < ${TMPFOLDER}/Recipientsbymessagesize
$MOVEF ${TMPFOLDER}/Recipientsbymessagesize_tmp ${TMPFOLDER}/Recipientsbymessagesize &> /dev/null

#======================================================
# Extract Information into variable -> Recipients by messagesize Table
#======================================================
while IFS= read -r var
do
    MessageswithnosizedataTable=""
    MessageswithnosizedataTable+="<tr>"
    MessageswithnosizedataTable+=$(echo "$var" | awk '{print "<td>"$1"</td>""<td>"$2"</td>"}')
    MessageswithnosizedataTable+="</tr>"
    echo $MessageswithnosizedataTable >> ${TMPFOLDER}/Messageswithnosizedata_tmp
    echo $MessageswithnosizedataTable
done < ${TMPFOLDER}/Messageswithnosizedata
$MOVEF  ${TMPFOLDER}/Messageswithnosizedata_tmp ${TMPFOLDER}/Messageswithnosizedata  &> /dev/null

#======================================================
# Single PAGE INDEX HTML TEMPLATE
# Using embedded HTML makes the script highly portable
# SED search and replace tags to fill the content
#======================================================

cat > $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD << 'HTMLOUTPUTINDEXDASHBOARD'
<!doctype html>
<html lang="en">

<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
    <meta name="description" content="Postfix PFLOGSUMM Dashboard Index">
    <meta name="author" content="Riaan Pretorius">
    <link rel="icon" href="http://www.postfix.org/favicon.ico">

    <title>Postfix PFLOGSUMM Dashboard Index</title>

    <!-- Bootstrap core CSS -->
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/4.1.3/css/bootstrap.min.css">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/4.7.0/css/font-awesome.css">


    <style>
        body {
            padding-top: 5rem;
        }

        footer {
            background-color: #eee;
            padding: 25px;
        }

        .spacer10 {
            height: 10px;
        }
    </style>

</head>

<body>

    <nav class="navbar navbar-expand-md navbar-dark bg-dark fixed-top">
        <a class="navbar-brand" href="#">Postfix PFLOGSUMM Dashboard</a>
    </nav>




    <div class="container">


        <h3 class="pb-3 mb-4 font-italic border-bottom">
            Select Report
            <dl class="row">
                <dt class="col-sm-3" style="font-size: 0.5em;">Last Update</dt>
                <dd class="col-sm-9" style="font-size: 0.5em;">##REPORTDATE##</dd>
                <dt class="col-sm-3" style="font-size: 0.5em;">Server</dt>
                <dd class="col-sm-9" style="font-size: 0.5em;">##ACTIVEHOSTNAME##</dd>

            </dl>
        </h3>


        <div class="row">

            <div class="col-sm">

                <!-- January Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">January</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##JanuaryCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#JanuaryCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="JanuaryCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush JanuaryList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- January End -->

            </div>

            <div class="col-sm">

                <!-- February Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">February</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##FebruaryCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#FebruaryCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="FebruaryCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush FebruaryList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- February End -->

            </div>

            <div class="col-sm">

                <!-- March Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">March</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##MarchCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#MarchCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="MarchCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush MarchList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- March End -->

            </div>

            <div class="col-sm">

                <!-- April Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">April</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##AprilCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#AprilCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="AprilCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush AprilList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- April End -->

            </div>


        </div>

        <br>

        <div class="row">

            <div class="col-sm">

                <!-- May Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">May</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##MayCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#MayCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="MayCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush MayList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- May End -->

            </div>

            <div class="col-sm">

                <!-- June Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">June</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##JuneCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#JuneCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="JuneCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush JuneList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- June End -->

            </div>

            <div class="col-sm">

                <!-- July Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">July</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##JulyCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#JulyCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="JulyCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush JulyList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- July End -->

            </div>

            <div class="col-sm">

                <!-- August Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">August</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##AugustCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#AugustCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="AugustCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush AugustList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- August End -->

            </div>

        </div>

        <br>

        <div class="row">

            <div class="col-sm">

                <!-- September Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">September</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##SeptemberCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#SeptemberCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="SeptemberCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush SeptemberList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- September End -->

            </div>

            <div class="col-sm">

                <!-- October Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">October</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##OctoberCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#OctoberCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="OctoberCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush OctoberList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- October End -->

            </div>

            <div class="col-sm">

                <!-- November Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">November</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##NovemberCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#NovemberCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="NovemberCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush NovemberList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- November End -->

            </div>

            <div class="col-sm">

                <!-- December Start-->
                <div class="card flex-md-row mb-4 shadow-sm h-md-250">
                    <div class="card-body d-flex flex-column align-items-start">
                        <h5><strong class="d-inline-block mb-2 text-primary">December</strong></h5>
                        <h6>Report Count <span class="badge badge-primary">##DecemberCount##</span></h6>
                        <div class="spacer10"></div>
                        <a data-toggle="collapse" href="#DecemberCard" aria-expanded="true" class="d-block"> View
                            Reports </a>
                        <div id="DecemberCard" class="collapse hide">
                            <div class="card-body " style="padding: 0.3rem;">
                                <div class="list-group list-group-flush DecemberList ">
                                    <!-- Dynamic Item List-->
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- December End -->

            </div>

        </div>

    </div>



    <br>

    <!-- Footer -->
    <footer class="container-fluid bg-dark text-center text-white-50">
        <div class="copyrights" style="margin-top:5px;">
            <p>&copy;
                <script>new Date().getFullYear() > 2010 && document.write(new Date().getFullYear());</script>
                <br>
                <span>Powered by <a href="https://github.com/KTamas/pflogsumm">PFLOGSUMM</a> </span> /
                <span><a href="https://github.com/RiaanPretoriusSA/PFLogSumm-HTML-GUI">PFLOGSUMM HTML UI Report</a>
                </span>
            </p>
        </div>
    </footer>
    <!-- Footer -->


    <!-- Bootstrap core JavaScript
    ================================================== -->
    <!-- Placed at the end of the document so the pages load faster -->
    <script src="https://cdnjs.cloudflare.com/ajax/libs/jquery/3.3.1/jquery.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/4.1.3/js/bootstrap.min.js"></script>
    <!-- Popper.JS -->
    <script src="https://cdnjs.cloudflare.com/ajax/libs/popper.js/1.14.5/umd/popper.min.js"></script>

</body>


<script>
    $(document).ready(function () {
        $('.JanuaryList').load("data/jan_rpt.html?rnd=" + Math.random());
        $('.FebruaryList').load("data/feb_rpt.html?rnd=" + Math.random());
        $('.MarchList').load("data/mar_rpt.html?rnd=" + Math.random());
        $('.AprilList').load("data/apr_rpt.html?rnd=" + Math.random());
        $('.MayList').load("data/may_rpt.html?rnd=" + Math.random());
        $('.JuneList').load("data/jun_rpt.html?rnd=" + Math.random());
        $('.JulyList').load("data/jul_rpt.html?rnd=" + Math.random());
        $('.AugustList').load("data/aug_rpt.html?rnd=" + Math.random());
        $('.SeptemberList').load("data/sep_rpt.html?rnd=" + Math.random());
        $('.OctoberList').load("data/oct_rpt.html?rnd=" + Math.random());
        $('.NovemberList').load("data/nov_rpt.html?rnd=" + Math.random());
        $('.DecemberList').load("data/dec_rpt.html?rnd=" + Math.random());
    });
</script>



</body>

</html>
HTMLOUTPUTINDEXDASHBOARD



#======================================================
# Single PAGE REPORT HTML TEMPLATE
# Using embedded HTML makes the script highly portable
# SED search and replace tags to fill the content
#======================================================
#2018-Nov-17.html

cat > $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html << 'HTMLREPORTDASHBOARD'
<!doctype html>
<html lang="en">

<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
    <meta name="description" content="Postfix Report">
    <meta name="author" content="">
    <link rel="icon" href="http://www.postfix.org/favicon.ico">

    <title>Postfix PFLOGSUMM Report</title>

    <!-- Bootstrap core CSS -->
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/4.1.3/css/bootstrap.min.css">
    <link rel="stylesheet" href="https://use.fontawesome.com/releases/v5.4.2/css/all.css" integrity="sha384-/rXc/GQVaYpyDdyxK+ecHPVYJSN9bmVFBvjA/9eOB+pb3F2w2N6fc5qB9Ew5yIns"
        crossorigin="anonymous">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/prism/1.15.0/themes/prism.css">



    <style>
        body {
            padding-top: 5rem;
        }

        footer {
            background-color: #eee;
            padding: 25px;
        }

        .spacer15 {
            height: 15px;
        }
    </style>

</head>

<body>

    <nav class="navbar navbar-expand-md navbar-dark bg-dark fixed-top">
        <a class="navbar-brand" href="../">Postfix Report</a>
    </nav>


    <!-- Server/Report INFO -->

    <div class="container rounded shadow-sm p-3 my-3 text-white bg-dark">
        <div class="row text-center">
                    <div class="col-lg-3">
                        <div> <strong>Hostname</strong> </div>
                        <h6 class="mb-3">##ACTIVEHOSTNAME##</h6>
                    </div>
                    <div class="col-lg-3">
                        <div> <strong>Report Date</strong> </div>
                        <div>##REPORTDATE##</div>
                    </div>
                    <div class="col-lg-3">
                        <div> <strong>Raw file</strong> </div>
                        <div><a href="##RAWFILELINK##">##RAWFILENAME##</a></div>
                    </div>
        </div>
    </div>
    <!-- Server/Report INFO -->

    <br>

    <!-- Quick Status Blocks -->
    <div class="container rounded shadow-sm p-3 my-3 text-white bg-dark ">
        <!-- Row -->
        <div class="row counter-box text-center">
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##ReceivedEmail##</span></h5>
                    <span style="font-size: 0.85em;">Received Email</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##DeliveredEmail##</span></h5>
                    <span style="font-size: 0.85em;">Delivered Mail</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##DeliveredEmailRemote##</span></h5>
                    <span style="font-size: 0.85em;">Remote Delivered ##DeliveredEmailRemotePercentage##</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##DeliveredEmailLocal##</span></h5>
                    <span style="font-size: 0.85em;">Local Delivered ##DeliveredEmailLocalPercentage##</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##DeferredEmailCount##</span></h5>
                    <span style="font-size: 0.85em;">Deferred ##DeferredEmailDeferralsCount##</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##BouncedEmail##</span></h5>
                    <span style="font-size: 0.85em;">Bounced Mail</span>
                </div>
            </div>
            <!-- column  -->
        </div>

        <div class="spacer15"></div>

        <!-- Row -->
        <div class="row counter-box text-center">
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##ForwardedEmail##</span></h5>
                    <span style="font-size: 0.85em;">Forwarded Mail</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##RejectedWarningsEmail##</span></h5>
                    <span style="font-size: 0.85em;">Rejected Warning ##RejectedEmailPercentage##</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##RejectedEmailCount##</span></h5>
                    <span style="font-size: 0.85em;">Rejected Mail ##RejectedEmailPercentage##</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##HeldEmail##</span></h5>
                    <span style="font-size: 0.85em;">Held Mail</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##DiscardedEmailCount##</span></h5>
                    <span style="font-size: 0.85em;">Discarded Mail ##DiscardedEmailPercentage##</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##SendingHostsDomainsEmail##</span></h5>
                    <span style="font-size: 0.85em;">Sending Hosts/Domains</span>
                </div>
            </div>
            <!-- column  -->
        </div>

        <div class="spacer15"></div>

        <!-- Row -->
        <div class="row counter-box text-center">
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##SendersEmail##</span></h5>
                    <span style="font-size: 0.85em;">Mail Senders</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##RecipientsEmail##</span></h5>
                    <span style="font-size: 0.85em;">Mail Recipients</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##BytesReceivedEmail##</span></h5>
                    <span style="font-size: 0.85em;">Bytes Received</span>
                </div>
            </div>
            <!-- column  -->
            <!-- column  -->
            <div class="col-lg-2 col-6">
                <div class="">
                    <h5 class="font-mute text-mute"><span class="counter font-weight-bold">##BytesDeliveredEmail##</span></h5>
                    <span style="font-size: 0.85em;">Bytes Delivered</span>
                </div>
            </div>
            <!-- column  -->
        </div>
        <!-- Quick Status Blocks -->
    </div>



    <div class="container rounded shadow-sm  p-3 my-3 ">

        <div class="my-3 p-3 bg-white  rounded shadow-sm">
            <h6 class="border-bottom border-gray pb-2 mb-0">Graphs</h6>

            <div class="container">
                <div class="row">
                    <div class="col-md-12">
                        <div id="PerDayTrafficSummaryTableGraph" style="width: auto; height: 400px; "></div>
                    </div>
                </div>
            </div>

            <div class="container">
                <div class="row">
                    <div class="col-md-12">
                        <div id="PerHourTrafficSummaryTableGraph" style="width: auto; height: 400px;"></div>
                    </div>
                </div>
            </div>
        </div>


        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#PerDayTrafficSummary" role="button" aria-expanded="false" aria-controls="PerDayTrafficSummary">
                <h6 class="border-bottom border-gray pb-2 mb-0">Per-Day Traffic Summary</h6>
            </a>
            <div class="container collapse" id="PerDayTrafficSummary">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive" id="PerDayTrafficSummaryTable">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Date</th>
                                        <th scope="col">Received</th>
                                        <th scope="col">Delivered</th>
                                        <th scope="col">Deferred</th>
                                        <th scope="col">Bounced</th>
                                        <th scope="col">Rejected</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##PerDayTrafficSummaryTable##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#PerHourTrafficSummary" role="button" aria-expanded="false"
                aria-controls="PerHourTrafficSummary">
                <h6 class="border-bottom border-gray pb-2 mb-0">Per-Hour Traffic Summary</h6>
            </a>
            <div class="container collapse" id="PerHourTrafficSummary">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive" id="PerHourTrafficSummaryTable">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Time</th>
                                        <th scope="col">Received</th>
                                        <th scope="col">Delivered</th>
                                        <th scope="col">Deferred</th>
                                        <th scope="col">Bounced</th>
                                        <th scope="col">Rejected</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##PerHourTrafficSummaryTable##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>


        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#HostDomainSummaryMessagesReceived" role="button" aria-expanded="false"
                aria-controls="HostDomainSummaryMessagesReceived">
                <h6 class="border-bottom border-gray pb-2 mb-0">Host/Domain Summary: Messages Received</h6>
            </a>
            <div class="container collapse" id="HostDomainSummaryMessagesReceived">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Message Count</th>
                                        <th scope="col">Bytes</th>
                                        <th scope="col">Host/Domain</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##HostDomainSummaryMessagesReceived##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#RemoteDomains" role="button" aria-expanded="false" aria-controls="RemoteDomains">
                <h6 class="border-bottom border-gray pb-2 mb-0">Remote Domains by Message Count</h6>
            </a>
            <div class="container collapse" id="RemoteDomains">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Message Count</th>
                                        <th scope="col">Remote Domain</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##RemoteDomains##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#RemoteRecipients" role="button" aria-expanded="false" aria-controls="RemoteRecipients">
                <h6 class="border-bottom border-gray pb-2 mb-0">Remote Recipients by Message Count</h6>
            </a>
            <div class="container collapse" id="RemoteRecipients">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Message Count</th>
                                        <th scope="col">Remote Recipient</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##RemoteRecipients##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#LocalDomains" role="button" aria-expanded="false" aria-controls="LocalDomains">
                <h6 class="border-bottom border-gray pb-2 mb-0">Local Domains by Message Count</h6>
            </a>
            <div class="container collapse" id="LocalDomains">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Message Count</th>
                                        <th scope="col">Local Domain</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##LocalDomains##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#LocalRecipients" role="button" aria-expanded="false" aria-controls="LocalRecipients">
                <h6 class="border-bottom border-gray pb-2 mb-0">Local Recipients by Message Count</h6>
            </a>
            <div class="container collapse" id="LocalRecipients">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Message Count</th>
                                        <th scope="col">Local Recipient</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##LocalRecipients##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#SendersbyMessageSize" role="button" aria-expanded="false" aria-controls="SendersbyMessageSize">
                <h6 class="border-bottom border-gray pb-2 mb-0">Senders by Message Size</h6>
            </a>
            <div class="container collapse" id="SendersbyMessageSize">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Size</th>
                                        <th scope="col">Sender</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##SendersbyMessageSize##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#SendersbyMessageCount" role="button" aria-expanded="false" aria-controls="SendersbyMessageCount">
                <h6 class="border-bottom border-gray pb-2 mb-0">Senders by Message Count</h6>
            </a>
            <div class="container collapse" id="SendersbyMessageCount">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Message Count</th>
                                        <th scope="col">Sender</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##Sendersbymessagecount##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#RecipientsbyMessageCount" role="button" aria-expanded="false"
                aria-controls="RecipientsbyMessageCount">
                <h6 class="border-bottom border-gray pb-2 mb-0">Recipients by Message Count</h6>
            </a>
            <div class="container collapse" id="RecipientsbyMessageCount">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Message Count</th>
                                        <th scope="col">Recipient</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##RecipientsbyMessageCount##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>


        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#HostDomainSummaryMessageDelivery" role="button" aria-expanded="false"
                aria-controls="HostDomainSummaryMessageDelivery">
                <h6 class="border-bottom border-gray pb-2 mb-0">Host/Domain Summary: Message Delivery</h6>
            </a>
            <div class="container collapse" id="HostDomainSummaryMessageDelivery">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Sent Count</th>
                                        <th scope="col">Bytes</th>
                                        <th scope="col">Defers</th>
                                        <th scope="col">Average Daily</th>
                                        <th scope="col">Maximum Daily</th>
                                        <th scope="col">Host/Domain</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##HostDomainSummaryMessageDelivery##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>


        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#Recipientsbymessagesize" role="button" aria-expanded="false" aria-controls="Recipientsbymessagesize">
                <h6 class="border-bottom border-gray pb-2 mb-0">Recipients by message size</h6>
            </a>
            <div class="container collapse" id="Recipientsbymessagesize">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Size</th>
                                        <th scope="col">Recipient</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##Recipientsbymessagesize##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#Messageswithnosizedata" role="button" aria-expanded="false" aria-controls="Messageswithnosizedata">
                <h6 class="border-bottom border-gray pb-2 mb-0">Messages with no size data</h6>
            </a>
            <div class="container collapse" id="Messageswithnosizedata">
                <div class="row">
                    <div class="col-md-12">
                        <div class="table-responsive">
                            <table class="table-responsive table-striped table-sm">
                                <thead>
                                    <tr>
                                        <th scope="col">Queue ID</th>
                                        <th scope="col">Email Address</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    ##Messageswithnosizedata##
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>


        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#MessageDeferralDetail" role="button" aria-expanded="false" aria-controls="MessageDeferralDetail">
                <h6 class="border-bottom border-gray pb-2 mb-0">Message Deferral Detail</h6>
            </a>
            <div class="container collapse" id="MessageDeferralDetail">
                <div class="row">
                    <div class="col-md-12">
                        <br>
                        <div class="pre-scrollable" style="max-height: 40vh; ">
                            <pre>
                                    ##MessageDeferralDetail##
                        </pre>
                        </div>
                        <br>
                    </div>
                </div>
            </div>
        </div>



        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#MessageBounceDetailbyrelay" role="button" aria-expanded="false"
                aria-controls="MessageBounceDetailbyrelay">
                <h6 class="border-bottom border-gray pb-2 mb-0">Message Bounce Detail (By Relay)</h6>
            </a>
            <div class="container collapse" id="MessageBounceDetailbyrelay">
                <div class="row">
                    <div class="col-md-12">
                        <br>
                        <div class="pre-scrollable" style="max-height: 40vh; ">
                            <pre>
                                        ##MessageBounceDetailbyrelay##
                            </pre>
                        </div>
                        <br>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#MailWarnings" role="button" aria-expanded="false" aria-controls="MailWarnings">
                <h6 class="border-bottom border-gray pb-2 mb-0">Mail Warnings</h6>
            </a>
            <div class="container collapse" id="MailWarnings">
                <div class="row">
                    <div class="col-md-12">
                        <br>
                        <div class="pre-scrollable" style="max-height: 40vh; ">
                            <pre>
                                            ##MailWarnings##
                                </pre>
                        </div>
                        <br>
                    </div>
                </div>
            </div>
        </div>

        <div class="my-3 p-3 bg-white rounded shadow-sm">
            <a data-toggle="collapse" href="#MailFatalErrors" role="button" aria-expanded="false" aria-controls="MailFatalErrors">
                <h6 class="border-bottom border-gray pb-2 mb-0">Mail Fatal Errors</h6>
            </a>
            <div class="container collapse" id="MailFatalErrors">
                <div class="row">
                    <div class="col-md-12">
                        <br>
                        <div class="pre-scrollable" style="max-height: 40vh; ">
                            <pre>
                                        ##MailFatalErrors##
                                    </pre>
                        </div>
                        <br>
                    </div>
                </div>
            </div>
        </div>
    </div>





    <br>


    <!-- Footer -->
    <footer class="container-fluid bg-dark text-center text-white-50">
        <div class="copyrights" style="margin-top:5px;">
            <p>&copy;
                <script>new Date().getFullYear() > 2010 && document.write(new Date().getFullYear());</script>
                <br>
                <span>Powered by <a href="https://github.com/KTamas/pflogsumm">PFLOGSUMM</a> </span> /
                <span><a href="https://github.com/RiaanPretoriusSA/PFLogSumm-HTML-GUI">PFLOGSUMM HTML UI Report</a>
                </span>
            </p>
        </div>
    </footer>




    <!-- Bootstrap core JavaScript
    ================================================== -->
    <!-- Placed at the end of the document so the pages load faster -->
    <script src="https://code.jquery.com/jquery-3.2.1.slim.min.js" integrity="sha384-KJ3o2DKtIkvYIK3UENzmM7KCkRr/rE9/Qpg6aAZGJwFDMVNA/GpGFF93hXpG5KkN"
        crossorigin="anonymous"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/popper.js/1.12.9/umd/popper.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/4.1.3/js/bootstrap.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/waypoints/4.0.1/jquery.waypoints.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/Counter-Up/1.0.0/jquery.counterup.js"></script>


    <!-- Icons -->
    <script src="https://unpkg.com/feather-icons/dist/feather.min.js"></script>
    <script>
        feather.replace()
    </script>

    <!-- Graphs -->
    <script src="https://code.highcharts.com/highcharts.js"></script>
    <script src="https://code.highcharts.com/modules/data.js"></script>
    <script src="https://code.highcharts.com/modules/exporting.js"></script>
    <script src="https://code.highcharts.com/modules/export-data.js"></script>

    <!-- Code Highlight-->
    <script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.15.0/prism.min.js"></script>




    <script>

        Highcharts.chart('PerDayTrafficSummaryTableGraph', {
            data: {
                table: 'PerDayTrafficSummaryTable'
            },
            chart: {
                type: 'line'
            },
            title: {
                text: 'Per-Day Traffic Summary'
            },
            yAxis: {
                allowDecimals: false,
                title: {
                    text: 'Units'
                }
            },

            plotOptions: {
                line: {
                    dataLabels: {
                        enabled: true
                    },
                    enableMouseTracking: false
                }
            }

        });


        Highcharts.chart('PerHourTrafficSummaryTableGraph', {
            data: {
                table: 'PerHourTrafficSummaryTable'
            },
            chart: {
                type: 'line'
            },
            title: {
                text: 'Per-Hour Traffic Summary'
            },
            yAxis: {
                allowDecimals: false,
                title: {
                    text: 'Units'
                }
            },

            plotOptions: {
                line: {
                    dataLabels: {
                        enabled: true
                    },
                    enableMouseTracking: false
                }
            },



        });

    </script>




    <script>
        jQuery(document).ready(function ($) {
            $('.counter').counterUp({
                delay: 1,
                time: 100
            });
        });
    </script>

</body>

</html>
HTMLREPORTDASHBOARD


#======================================================
# Replace Placeholders with values - GrandTotals
#======================================================
sed -i "s/##REPORTDATE##/$REPORTDATE/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##ACTIVEHOSTNAME##/$ACTIVEHOSTNAME/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s|##RAWFILELINK##|$RAWFILELINK|g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s|##RAWFILENAME##|$RAWFILENAME|g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##ReceivedEmail##/$ReceivedEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##DeliveredEmail##/$DeliveredEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##DeliveredEmailRemote##/$DeliveredEmailRemote/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##DeliveredEmailRemotePercentage##/$DeliveredEmailRemotePercentage/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##DeliveredEmailLocal##/$DeliveredEmailLocal/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##DeliveredEmailLocalPercentage##/$DeliveredEmailLocalPercentage/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##ForwardedEmail##/$ForwardedEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##DeferredEmailCount##/$DeferredEmailCount/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##DeferredEmailDeferralsCount##/$DeferredEmailDeferralsCount/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##BouncedEmail##/$BouncedEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##RejectedEmailCount##/$RejectedEmailCount/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##RejectedEmailPercentage##/$RejectedEmailPercentage/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##RejectedWarningsEmail##/$RejectedWarningsEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##HeldEmail##/$HeldEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##DiscardedEmailCount##/$DiscardedEmailCount/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##DiscardedEmailPercentage##/$DiscardedEmailPercentage/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##BytesReceivedEmail##/$BytesReceivedEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##BytesDeliveredEmail##/$BytesDeliveredEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##SendersEmail##/$SendersEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##SendingHostsDomainsEmail##/$SendingHostsDomainsEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##RecipientsEmail##/$RecipientsEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html
sed -i "s/##RecipientHostsDomainsEmail##/$RecipientHostsDomainsEmail/g" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table PerDayTrafficSummaryTable
#======================================================
sed -i "/##PerDayTrafficSummaryTable##/ {
r ${TMPFOLDER}/PerDayTrafficSummary
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html


#======================================================
# Replace Placeholders with values - Table PerHourTrafficSummaryTable
#======================================================
sed -i "/##PerHourTrafficSummaryTable##/ {
r ${TMPFOLDER}/PerHourTrafficSummary
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html


#======================================================
# Replace Placeholders with values - Table HostDomainSummaryMessageDelivery
#======================================================
sed -i "/##HostDomainSummaryMessageDelivery##/ {
r ${TMPFOLDER}/HostDomainSummaryMessageDelivery
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table HostDomainSummaryMessagesReceived
#======================================================
sed -i "/##HostDomainSummaryMessagesReceived##/ {
r ${TMPFOLDER}/HostDomainSummaryMessagesReceived
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table RemoteDomains
#======================================================
sed -i "/##RemoteDomains##/ {
r ${TMPFOLDER}/RemoteDomains
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table RemoteRecipients
#======================================================
sed -i "/##RemoteRecipients##/ {
r ${TMPFOLDER}/RemoteRecipients
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table LocalDomains
#======================================================
sed -i "/##LocalDomains##/ {
r ${TMPFOLDER}/LocalDomains
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table LocalRecipients
#======================================================
sed -i "/##LocalRecipients##/ {
r ${TMPFOLDER}/LocalRecipients
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table Sendersbymessagecount
#======================================================
sed -i "/##Sendersbymessagecount##/ {
r ${TMPFOLDER}/Sendersbymessagecount
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table RecipientsbyMessageCount
#======================================================
sed -i "/##RecipientsbyMessageCount##/ {
r ${TMPFOLDER}/Recipientsbymessagecount
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table SendersbyMessageSize
#======================================================
sed -i "/##SendersbyMessageSize##/ {
r ${TMPFOLDER}/Sendersbymessagesize
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table Recipientsbymessagesize
#======================================================
sed -i "/##Recipientsbymessagesize##/ {
r ${TMPFOLDER}/Recipientsbymessagesize
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html

#======================================================
# Replace Placeholders with values - Table Messageswithnosizedata
#======================================================
sed -i "/##Messageswithnosizedata##/ {
r ${TMPFOLDER}/Messageswithnosizedata
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html


#======================================================
# Replace Placeholders with values -  MessageDeferralDetail
#======================================================
sed -i "/##MessageDeferralDetail##/ {
r ${TMPFOLDER}/messagedeferraldetail
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html 

#======================================================
# Replace Placeholders with values -  MessageBounceDetailbyrelay
#======================================================
sed -i "/##MessageBounceDetailbyrelay##/ {
r ${TMPFOLDER}/messagebouncedetaibyrelay
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html 


#======================================================
# Replace Placeholders with values - warnings
#======================================================
sed -i "/##MailWarnings##/ {
r ${TMPFOLDER}/warnings
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html 


#======================================================
# Replace Placeholders with values - FatalErrors
#======================================================
sed -i "/##MailFatalErrors##/ {
r ${TMPFOLDER}/FatalErrors
d
}" $DATADIR/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.html




#======================================================
# Count Existing Reports - For Dashboard Display
#======================================================
JanRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Jan*.html | wc -l)
FebRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Feb*.html | wc -l)
MarRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Mar*.html | wc -l)
AprRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Apr*.html | wc -l)
MayRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-May*.html | wc -l)
JunRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Jun*.html | wc -l)
JulRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Jul*.html | wc -l)
AugRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Aug*.html | wc -l)
SepRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Sep*.html | wc -l)
OctRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Oct*.html | wc -l)
NovRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Nov*.html | wc -l)
DecRPTCount=$(find $DATADIR  -maxdepth 1 -type f -name $CURRENTYEAR-Dec*.html | wc -l)


#======================================================
# Replace Report Totals for Report - Index
#======================================================
sed -i "s/##JanuaryCount##/$JanRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##FebruaryCount##/$FebRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##MarchCount##/$MarRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##AprilCount##/$AprRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##MayCount##/$MayRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##JuneCount##/$JunRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##JulyCount##/$JulRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##AugustCount##/$AugRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##SeptemberCount##/$SepRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##OctoberCount##/$OctRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##NovemberCount##/$NovRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##DecemberCount##/$DecRPTCount/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD

sed -i "s/##REPORTDATE##/$REPORTDATE/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD
sed -i "s/##ACTIVEHOSTNAME##/$ACTIVEHOSTNAME/g" $HTMLOUTPUTDIR/$HTMLOUTPUT_INDEXDASHBOARD


#======================================================
# Update Clickable Index Files (imported dynamicly)
#======================================================

#Delete Exisitng File Indexs
rm -fr $DATADIR/*_rpt.html

#Get List of report files
for filename in $DATADIR/*.html; do
    filenameWithExtOnly="${filename##*/}"
    filenameWithoutExtension="${filenameWithExtOnly%.*}"
 
    case $filenameWithExtOnly in
        *Jan* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/jan_rpt.html
        ;;

        *Feb* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/feb_rpt.html
        ;;

        *Mar* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/mar_rpt.html
        ;;

        *Apr* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/apr_rpt.html
        ;;

        *May* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/may_rpt.html
        ;;

        *Jun* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/jun_rpt.html
        ;;

        *Jul* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/jul_rpt.html
        ;;

        *Aug* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/aug_rpt.html
        ;;

        *Sep* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/sep_rpt.html
        ;;

        *Oct* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/oct_rpt.html
        ;;

        *Nov* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/nov_rpt.html
        ;;

        *Dec* )
        echo "<a href=\"data/${filenameWithoutExtension}.html\" class=\"list-group-item list-group-item-action\">$filenameWithoutExtension</a>" >> $DATADIR/dec_rpt.html
        ;;
    esac
done


#======================================================
# Save Raw log file
#======================================================

#Store raw file
cp ${DAILY_REPORT} ${RAWDIR}/$CURRENTYEAR-$CURRENTMONTH-$CURRENTDAY.txt



#======================================================
# Clean UP
#======================================================

#Finally remove temp folder
rm -Rf ${TMPFOLDER}

#Perform a clean-up of files up to 1 year in RawDir
find ${RAWDIR}/ -type f -mtime +365 -delete

#Remove empty directories for RawDir
find ${RAWDIR}/ -type d -empty -delete

#Perform a clean-up of files up to 1 year in DataDir
find ${DATADIR}/ -type f -name "*.html" -mtime +365 | while read file
do
	filename="$(basename "${file}")"

	# Let's find out the index pointing to the file
	find ${DATADIR} -type f -name "*rpt.html" -exec grep -l "${filename}" {} \; | while read index
	do
		sed -i "/${filename}/d" ${index}
	done

	# Finally remove file
	rm -f ${file}
done







