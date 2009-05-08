#!/usr/bin/env perl
# 00_compile.t
# written by Paul Mantz <pcmantz@zmanda.com>
# created 29 Dec 2008
# Version v0.01
# Copyright (C) 2008, Paul Mantz

##############################################################################
# Libraries
##############################################################################

use strict;
use warnings;

use Cwd qw/abs_path/;

use Test::More qw( no_plan );

use lib '../lib';


##############################################################################
# Begin Block
##############################################################################

BEGIN {
}

##############################################################################
# Tests
##############################################################################

my $lib = abs_path('../lib');
my $bin = abs_path('../bin');

sub checkFile
{
    my ($perlFile) = shift @_;

    my $retval = system( split (' ',  "perl -cwT -I $lib $perlFile 2>/dev/null 1>/dev/null") );
    is($retval, 0, "compiled test: $perlFile")
}


my @libFiles = qw{
  ../lib/BackupPC/Attrib.pm
  ../lib/BackupPC/Config.pm
  ../lib/BackupPC/FileZIO.pm
  ../lib/BackupPC/Lib.pm
  ../lib/BackupPC/PoolWrite.pm
  ../lib/BackupPC/Storage.pm
  ../lib/BackupPC/View.pm
  ../lib/BackupPC/Xfer.pm
  ../lib/BackupPC/CGI/AdminOptions.pm
  ../lib/BackupPC/CGI/Archive.pm
  ../lib/BackupPC/CGI/ArchiveInfo.pm
  ../lib/BackupPC/CGI/Browse.pm
  ../lib/BackupPC/CGI/DirHistory.pm
  ../lib/BackupPC/CGI/EditConfig.pm
  ../lib/BackupPC/CGI/EmailSummary.pm
  ../lib/BackupPC/CGI/GeneralInfo.pm
  ../lib/BackupPC/CGI/HostInfo.pm
  ../lib/BackupPC/CGI/LOGlist.pm
  ../lib/BackupPC/CGI/Queue.pm
  ../lib/BackupPC/CGI/ReloadServer.pm
  ../lib/BackupPC/CGI/RestoreFile.pm
  ../lib/BackupPC/CGI/RestoreInfo.pm
  ../lib/BackupPC/CGI/Restore.pm
  ../lib/BackupPC/CGI/RSS.pm
  ../lib/BackupPC/CGI/StartServer.pm
  ../lib/BackupPC/CGI/StartStopBackup.pm
  ../lib/BackupPC/CGI/StopServer.pm
  ../lib/BackupPC/CGI/Summary.pm
  ../lib/BackupPC/CGI/View.pm
  ../lib/BackupPC/Config/Meta.pm
  ../lib/BackupPC/Lang/de.pm
  ../lib/BackupPC/Lang/en.pm
  ../lib/BackupPC/Lang/es.pm
  ../lib/BackupPC/Lang/fr.pm
  ../lib/BackupPC/Lang/it.pm
  ../lib/BackupPC/Lang/nl.pm
  ../lib/BackupPC/Lang/pl.pm
  ../lib/BackupPC/Lang/pt_br.pm
  ../lib/BackupPC/Lang/zh_CN.pm
  ../lib/BackupPC/Storage/Text.pm
  ../lib/BackupPC/Xfer/Archive.pm
  ../lib/BackupPC/Xfer/Ftp.pm
  ../lib/BackupPC/Xfer/Protocol.pm
  ../lib/BackupPC/Xfer/Smb.pm
  ../lib/BackupPC/Xfer/Tar.pm
  ../lib/BackupPC/Xfer/Local.pm
  ../lib/BackupPC/Xfer/Rsync.pm
  ../lib/BackupPC/Xfer/RsyncDigest.pm
  ../lib/BackupPC/Xfer/RsyncFileIO.pm
  ../lib/BackupPC/Zip/FileMember.pm
  ../lib/Net/FTP/AutoReconnect.pm
  ../lib/Net/FTP/RetrHandle.pm
};



foreach my $lib (@libFiles ) {
    checkFile($lib);
}


my @binFiles = qw{
  ../bin/BackupPC
  ../bin/BackupPC_archive
  ../bin/BackupPC_archiveHost
  ../bin/BackupPC_archiveStart
  ../bin/BackupPC_attribPrint
  ../bin/BackupPC_dump
  ../bin/BackupPC_fixupBackupSummary
  ../bin/BackupPC_link
  ../bin/BackupPC_nightly
  ../bin/BackupPC_restore
  ../bin/BackupPC_sendEmail
  ../bin/BackupPC_serverMesg
  ../bin/BackupPC_trashClean
  ../bin/BackupPC_tarExtract
  ../bin/BackupPC_tarCreate
  ../bin/BackupPC_tarPCCopy
  ../bin/BackupPC_zipCreate
  ../bin/BackupPC_zcat
};

foreach my $bin ( @binFiles) {
    checkFile($bin);
}
