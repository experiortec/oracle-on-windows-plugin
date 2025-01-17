#
# Copyright (c) 2020 by Delphix. All rights reserved.
#
# Author: Jatinder Luthra
# Date: 09-23-2020
###########################################################

$programName = 'ds_inc_crtRestoreScripts.ps1'
$delphixToolkitPath = $env:DLPX_TOOLKIT_PATH
$oracleHome = $env:ORACLE_HOME
$oraInstName = $env:ORACLE_INST
$oraUser = $env:ORACLE_USER
$oraPwd = $env:ORACLE_PASSWD
$oraBase = $env:ORACLE_BASE
$oraBkpLoc = $env:ORACLE_BKP_LOC
$stgMnt = $env:STG_MNT_PATH
$oraDbid = $env:ORACLE_DBID
$oraSrc = $env:ORA_SRC
$oraUnq = $env:ORA_UNQ_NAME
$DBlogDir = ${delphixToolkitPath}+"\logs\"+${oraUnq}
$restorecmdfile = "$DBlogDir\${oraUnq}.rstr"
$renamelogtempfile = "$DBlogDir\${oraUnq}.rnm"
$recovercmdfile = "$DBlogDir\${oraUnq}.rcv"

$scriptDir = "${delphixToolkitPath}\scripts"

$Env:ORACLE_BASE=$oraBase
$Env:ORACLE_SID=$oraInstName
$Env:ORACLE_HOME=$oracleHome

. $scriptDir\delphixLibrary.ps1
. $scriptDir\oracleLibrary.ps1

log "Executing $programName"

log "ORACLE_HOME: $oracleHome"
log "ORACLE_SID: $oraInstName"
log "ORACLE_USER: $oraUser"
log "ORACLE_BASE: $oraBase"
log "ORACLE_BKP_LOC: $oraBkpLoc"
log "STG_MNT_PATH: $stgMnt"
log "ORACLE_DBID: $oraDbid"
log "ORACLE_SRC_NAME: $oraSrc"
log "DB_LOG_DIR: $DBlogDir"
log "RESTORE_FILE: $restorecmdfile"
log "RENAME_LOG_TEMP_FILE: $renamelogtempfile"
log "RECOVERY_FILE: $recovercmdfile"

#### Creating DB Log Directory

if(!(Test-Path $DBlogDir)) {
      md $DBlogDir
log "[Creating DBLogDir] md $DBlogDir"
}
else {
log "[DBLogDir Already Exists] $DBlogDir"
   }

# set powershell default encoding to UTF8
$PSDefaultParameterValues['*:Encoding'] = 'ascii'

########### get_end_time

 $sqlQuery=@"
 WHENEVER SQLERROR EXIT SQL.SQLCODE
 set serveroutput off
 set feedback off
 set heading off
 set echo off
 set NewPage none
 select to_char(end_time,'dd-mon-yyyy hh24:mi:ss')||'|'|| INPUT_TYPE from (select max(END_TIME) end_time,INPUT_TYPE from V`$RMAN_BACKUP_JOB_DETAILS where INPUT_TYPE in ('DB FULL','DB INCR') and status= 'COMPLETED' group by INPUT_TYPE order by end_time desc)  where rownum=1;
 exit
"@

log "[SQL Query - get_end_time] $sqlQuery"

$result = $sqlQuery |  . $Env:ORACLE_HOME\bin\sqlplus.exe -silent " /as sysdba"

log "[get_end_time] $result"

if ($LASTEXITCODE -ne 0){
echo "Sql Query failed with ORA-$LASTEXITCODE"
exit 1
}

##### move existing to last
$index = $result.IndexOf("|")
$end_time = $result.Substring(0,$index).trim()
$backup_type = $result.Substring($index+1).trim()

log "[end_time] $end_time"
log "[backup_type] $backup_type"

mv $stgMnt\$oraSrc\new_ctl_bkp_endtime.txt $stgMnt\$oraSrc\last_ctl_bkp_endtime.txt -force

echo $end_time > "$stgMnt\$oraSrc\new_ctl_bkp_endtime.txt"

remove_empty_lines "$stgMnt\$oraSrc\new_ctl_bkp_endtime.txt"

#### get end scn

 $sqlQuery=@"
 WHENEVER SQLERROR EXIT SQL.SQLCODE
 set serveroutput off
 set feedback off
 set heading off
 set echo off
 set NewPage none
select (greatest(max(absolute_fuzzy_change#),max(checkpoint_change#))) "endscn" from (select file#, completion_time, checkpoint_change#, absolute_fuzzy_change# from v`$backup_datafile where (incremental_level in ( 0, 1 ) OR incremental_level is null) and trunc(completion_time) = trunc(to_date('$end_time','dd-mon-yyyy hh24:mi:ss')) and file# <> 0 and completion_time <= to_date('$end_time','dd-mon-yyyy hh24:mi:ss') order by completion_time desc);
 exit
"@

log "[SQL Query - get_end_scn] $sqlQuery"

$end_scn = $sqlQuery |  . $Env:ORACLE_HOME\bin\sqlplus.exe -silent " /as sysdba"

$end_scn = $end_scn -replace '\s',''
log "[end_scn] $end_scn"

if ($LASTEXITCODE -ne 0){
echo "Sql Query failed with ORA-$LASTEXITCODE"
exit 1
}

##### move existing to last
mv $stgMnt\$oraSrc\new_ctl_bkp_endscn.txt $stgMnt\$oraSrc\last_ctl_bkp_endscn.txt -force

echo $end_scn > "$stgMnt\$oraSrc\new_ctl_bkp_endscn.txt"

remove_empty_lines "$stgMnt\$oraSrc\new_ctl_bkp_endscn.txt"

#####

##### get list of new datafiles

log "Get Post DataFiles, $oraUnq STARTED"

$sqlQuery=@"
WHENEVER SQLERROR EXIT SQL.SQLCODE
set serveroutput off
 set feedback off
 set heading off
 set echo off
 set NewPage none
select file# from v`$datafile order by 1;
"@

log "[SQL Query - get_post_datafiles] $sqlQuery"

$result = $sqlQuery |  . $Env:ORACLE_HOME\bin\sqlplus.exe -silent " /as sysdba"
$result = $result -replace '\s',''
log "[get_post_datafiles] $result"

if ($LASTEXITCODE -ne 0){
echo "Sql Query failed with ORA-$LASTEXITCODE"
exit 1
}

echo $result > "$DBlogDir\post_datafiles.txt"

log "Get Post DataFiles, $oraUnq FINISHED"

#### compare datafiles pre and post

log "Compare Pre and Post Datafiles, $oraUnq STARTED"

$postdf = Get-Content -Path $DBlogDir\post_datafiles.txt
$predf = Get-Content -Path $DBlogDir\pre_datafiles.txt

$diff = Compare-Object $postdf $predf | ?{$_.sideindicator -eq '<='} | Select-Object -ExpandProperty InputObject

log "New Datafiles, $diff"

log "Compare Pre and Post Datafiles, $oraUnq FINISHED"

#### Create RMAN restore script

log "Creating Restore Scripts, $restorecmdfile STARTED"

echo "catalog start with '$oraBkpLoc\' noprompt;" > $restorecmdfile
echo "set echo on" >> $restorecmdfile
echo "RUN" >> $restorecmdfile
echo "{" >> $restorecmdfile
echo "ALLOCATE CHANNEL T1 DEVICE TYPE disk;" >> $restorecmdfile
echo "ALLOCATE CHANNEL T2 DEVICE TYPE disk;" >> $restorecmdfile

### rename datafiles

 $sqlQuery=@"
 WHENEVER SQLERROR EXIT SQL.SQLCODE
 set linesize 200 heading off feedback off
 col file_name format a200
select 'set newname for datafile ' ||FILE#|| ' to '||'''$stgMnt'||'\$oraSrc\'||SUBSTR(NAME,(INSTR(NAME,'\',-1)+1),LENGTH(NAME))||''';' filename from v`$datafile;
exit
"@

log "[SQL Query - rename_datafiles] $sqlQuery"

$result = $sqlQuery |  . $Env:ORACLE_HOME\bin\sqlplus.exe -silent " /as sysdba"

log "[rename_datafiles] $result"

if ($LASTEXITCODE -ne 0){
echo "Sql Query failed with ORA-$LASTEXITCODE"
exit 1
}

echo $result >> $restorecmdfile

echo "SET UNTIL SCN $end_scn;" >> $restorecmdfile

if (-not ([string]::IsNullOrEmpty($diff))){
  ForEach($file in $diff) {
      echo "restore datafile $file;" >> $restorecmdfile
    }
}

if ($backup_type -eq "DB FULL"){
      echo "restore database;" >> $restorecmdfile
}
echo "catalog start with '$stgMnt\$oraSrc\' noprompt;" >> $restorecmdfile
echo "SWITCH DATAFILE ALL;" >> $restorecmdfile
echo "RELEASE CHANNEL T1;" >> $restorecmdfile
echo "RELEASE CHANNEL T2;" >> $restorecmdfile
echo "}" >> $restorecmdfile
echo "EXIT" >> $restorecmdfile

## remove empty lines
remove_empty_lines $restorecmdfile

#### Create log file and temp files script

 $sqlQuery=@"
 WHENEVER SQLERROR EXIT SQL.SQLCODE
 set linesize 200 heading off feedback off
 col file_name format a200
select 'alter database rename file ''' ||member|| ''' to '||'''$stgMnt'||'\$oraSrc\'||SUBSTR(member,(INSTR(member,'\',-1)+1),LENGTH(member))||''';' member from v`$logfile;
exit
"@

log "[SQL Query - rename_logfiles] $sqlQuery"

$result = $sqlQuery |  . $Env:ORACLE_HOME\bin\sqlplus.exe -silent " /as sysdba"

log "[rename_logfiles] $result"

if ($LASTEXITCODE -ne 0){
echo "Sql Query failed with ORA-$LASTEXITCODE"
exit 1
}

echo $result > $renamelogtempfile

 $sqlQuery=@"
 WHENEVER SQLERROR EXIT SQL.SQLCODE
 set linesize 200 heading off feedback off
 col file_name format a200
select 'alter database rename file ''' ||name|| ''' to '||'''$stgMnt'||'\$oraSrc\'||SUBSTR(name,(INSTR(name,'\',-1)+1),LENGTH(name))||''';' name from v`$tempfile;
exit
"@

log "[SQL Query - rename_tempfiles] $sqlQuery"

$result = $sqlQuery |  . $Env:ORACLE_HOME\bin\sqlplus.exe -silent " /as sysdba"

log "[rename_tempfiles] $result"

if ($LASTEXITCODE -ne 0){
echo "Sql Query failed with ORA-$LASTEXITCODE"
exit 1
}

echo $result >> $renamelogtempfile
echo "exit" >> $renamelogtempfile

## remove empty lines
remove_empty_lines $renamelogtempfile

log "Creating Restore Scripts, $restorecmdfile FINISHED"

##### create recovery script

log "Creating Recovery Script, $recovercmdfile STARTED"

echo "set echo on" > $recovercmdfile
echo "RUN" >> $recovercmdfile
echo "{" >> $recovercmdfile
echo "ALLOCATE CHANNEL T1 DEVICE TYPE disk;" >> $recovercmdfile
echo "ALLOCATE CHANNEL T2 DEVICE TYPE disk;" >> $recovercmdfile
echo "SET UNTIL SCN $end_scn;" >> $recovercmdfile
echo "recover database;" >> $recovercmdfile
echo "RELEASE CHANNEL T1;" >> $recovercmdfile
echo "RELEASE CHANNEL T2;" >> $recovercmdfile
echo "}" >> $recovercmdfile
echo "EXIT" >> $recovercmdfile


log "Creating Recovery Script, $recovercmdfile FINISHED"
