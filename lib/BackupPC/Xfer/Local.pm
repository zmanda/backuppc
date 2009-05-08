#============================================================= -*-perl-*-
#
# BackupPC::Xfer::Local package
#
# DESCRIPTION
#
#   This library defines a BackupPC::Xfer::Local class for performing
#   backups of locally-accessible files.
#
# AUTHOR
#   Paul Mantz  <pcmantz@zmanda.com>
#
# COPYRIGHT
#   Copyright (C) 2009 Zmanda, Inc.
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#========================================================================
#
# Version __VERSION__, released __DATE__.
#
# See http://backuppc.sourceforge.net.
#
#========================================================================

package BackupPC::Xfer::Local;

use strict;

use Fcntl qw/:mode/;
use Encode qw/from_to encode/;
use POSIX qw/mkfifo/;
use File::stat qw/:FIELDS/;

use File::Find;
use File::Path;
use Data::Dumper;

use BackupPC::View;
use BackupPC::Attrib qw/:all/;

use base qw( BackupPC::Xfer::Protocol );
use vars qw( $UnixMknodOK $BufSize );

BEGIN {

    $BufSize = 1048576;

    undef $@;
    eval "use Unix::Mknod;";
    $UnixMknodOK = !( defined $@ );
};


sub start
{
    my ($t)      = @_;
    my $bpc      = $t->{bpc};
    my $conf     = $t->{conf};
    my $logMsg   = undef;
    my $incrDate = $t->{incrDate};

    ( $t->{shareNameSlash} = "$t->{shareName}/" ) =~ s{//+$}{/}g;

    from_to( $t->{shareName}, "utf8", $conf->{ClientCharset} )
      if ( $conf->{ClientCharset} ne "" );
    from_to( $t->{shareNameSlash}, "utf8", $conf->{ClientCharset} )
      if ( $conf->{ClientCharset} ne "" );

    if ( $t->{type} eq "restore" ) {
        $logMsg = "restore started for directory $t->{shareName}";

    } else {
        $bpc->backupFileConfFix( $conf, "LocalShareName" );

        if ( $t->{type} eq "full" ) {
            $logMsg = "full backup started for directory $t->{shareName}";
        } else {
            $incrDate = $bpc->timeStamp( $t->{incrBaseTime} - 3600, 1 );
            $logMsg = "incr backup started back to $incrDate"
              . " (backup #$t->{incrBaseBkupNum}) for directory"
              . " $t->{shareName}";
        }
    }

    #
    # Clean up and return
    #
    delete $t->{_errStr};
    return $logMsg;
}


sub run
{
    my ($t)  = @_;
    my $bpc  = $t->{bpc};
    my $conf = $t->{conf};

    if ( $t->{type} eq "restore" ) {
        $t->restore();
    } else {
        $t->backup();
    }

    my @results;
    if ( $t->{type} eq "restore" ) {
        @results =
          ( $t->{fileCnt}, $t->{byteCnt}, $t->{errCnt}, $t->{_errStr}, );

    } else {

        #
        # TODO: make statistics more meaningful
        #
        @results = (
            0,                # $tarErrs
            $t->{fileCnt},    # $nFilesExist
            $t->{byteCnt},    # $sizeExist
            0,                # $sizeExistComp
            $t->{fileCnt},    # $nfilesTotal
            $t->{byteCnt},    # $sizeTotal
        );
    }

    $t->{xferOK} = !( $t->{_errStr} );
    #print STDERR "error string = \"$t->{_errStr}\"\n";
    return wantarray ? @results : \@results;
}


#
# Backup Routines
#
sub backup
{
    my ($t)    = @_;
    my $bpc    = $t->{bpc};
    my $conf   = $t->{conf};
    my $TopDir = $bpc->TopDir();
    my $OutDir = $t->{OutDir} = "$TopDir/pc/$t->{client}/new/"
      . $bpc->fileNameEltMangle( $t->{shareName} );
    my $Attrib = $t->{Attrib} = {};

    $t->{view} = BackupPC::View->new( $bpc, $t->{client}, $t->{backups} );

    #
    # use File::Find iteration over the target shares.
    #
    $t->{wanted} =
      sub { $t->wanted( $_, $File::Find::dir, $File::Find::name ); };
    find(
        {
            wanted   => $t->{wanted},
            no_chdir => 0,
        },
        $t->{shareName}
    );

    #
    # flush any remaining attrib files
    #
    while ( my ( $dir, $attrib ) = each %$Attrib ) {
        $t->attributeWrite( $dir, $attrib );
    }
}


sub wanted
{
    my ( $t, $name, $dir, $fullName ) = @_;

    my $bpc        = $t->{bpc};
    my $OutDir     = $t->{OutDir};
    my $Attrib     = $t->{Attrib};
    my $shareName  = $t->{shareName};
    my $newFilesFH = $t->{newFilesFH};

    my $data     = undef;
    my $fh       = undef;
    my $devmajor = undef;
    my $devminor = undef;

    unless ( $t->checkIncludeExclude($fullName) ) {
        $File::Find::prune = 1;
        return;
    }

    $fullName =~ /$shareName(.*)/;
    my $relName = ( $1 eq "" ) ? "/" : $1;
    $relName =~ /(.*)\/$name/;
    my $relDir = ( $1 eq "" ) ? "/" : $1;

    #
    # using File::stat makes stat() return an object instead of a
    # tuple.
    #
    my $st         = stat($fullName);
    my $attribInfo = {
        type  => S_IFMT($st->mode),
        mode  => S_IMODE($st->mode),
        uid   => $st->uid,
        gid   => $st->gid,
        size  => $st->size,
        mtime => $st->mtime,
    };

    if ( !defined $Attrib->{$relDir} ) {
        foreach my $d ( keys %$Attrib ) {
            next if $relDir =~ /^$d/;
            $t->attributeWrite( $d, $Attrib->{$d} );
        }
        $Attrib->{$relDir} =
          BackupPC::Attrib->new( { compress => $t->{compress} } );
    }

    if ( S_ISDIR( $st->mode ) ) {

        #
        # Process the directory and return.
        #
        $attribInfo->{type} = BPC_FTYPE_DIR;
        eval { mkpath( "$OutDir/" . $bpc->fileNameMangle($relName), 0, 0755 ); };
        $t->logFileAction( "create", $name, $st );
        $Attrib->{$relDir}->set( $name, $attribInfo );
        return;

    } elsif ( S_ISREG( $st->mode ) ) {
        $attribInfo->{type} = BPC_FTYPE_FILE;
        open $fh, "<", $fullName;

    } elsif ( S_ISLNK( $st->mode ) ) {
        $attribInfo->{type} = BPC_FTYPE_SYMLINK;
        $data = readlink $fullName;

    } elsif ( S_ISBLK( $st->mode ) ) {
        $attribInfo->{type} = BPC_FTYPE_BLOCKDEV;

        if ($UnixMknodOK) {
            my $devmajor = major($st->rdev);
            my $devminor = minor($st->rdev);
        } else {
            my $devmajor = ( $st->dev & 0xff00 ) >> 8;
            my $devminor = ( $st->dev & 0xff ) | ( $st->dev >> 12 & ~0xff );
        }
        $data = "$devmajor,$devminor"

    } elsif ( S_ISCHR( $st->mode ) ) {
        $attribInfo->{type} = BPC_FTYPE_CHARDEV;

        if ($UnixMknodOK) {
            $devmajor = major($st->rdev);
            $devminor = minor($st->rdev);
        } else {
            $devmajor = ( $st->dev & 0xff00 ) >> 8;
            $devminor = ( $st->dev & 0xff ) | ( $st->dev >> 12 & ~0xff );
        }
        $data = "$devmajor,$devminor";

    } elsif ( S_ISFIFO( $st->mode ) ) {
        $attribInfo->{type} = BPC_FTYPE_FIFO;
        $data = "";

    } elsif ( S_ISSOCK( $st->mode ) ) {
        $File::Find::prune = 1;
        return;

    } else {
        $File::Find::prune = 1;
        return;
    }

    unless ( defined $fh xor defined $data ) {
        $t->logFileAction( "fail", $fullName, $attribInfo );
    }

    #
    # Write the file
    #
    my $poolFile = $OutDir . "/" . $bpc->fileNameMangle($relName);
    my $poolWrite =
      BackupPC::PoolWrite->new( $bpc, $poolFile,
        ( defined $fh ) ? $st->size : length $data,
        $t->{compress} );

    my $dataSize;
    if ( defined $fh ) {
        $dataSize = 0;
        while (<$fh>) {
            $dataSize += length($_);
            $poolWrite->write( \$_ );
        }

    } elsif ( defined $data ) {
        $dataSize = length $data;
        $poolWrite->write( \$data );
    }

    my ( $exists, $digest, $outSize, $errs ) = $poolWrite->close();
    if (@$errs) {
        $t->logFileAction( "fail", $fullName, $attribInfo );
        unlink($poolFile);
        $t->{xferBadFileCnt}++;
        $t->{errCnt} += scalar(@$errs);
        return;
    }

    $t->logFileAction( $exists ? "pool" : "create", $fullName, $attribInfo );
    print $newFilesFH "$digest $st->size $poolFile\n" unless $exists;
    $t->{byteCnt} += $dataSize;
    $t->{fileCnt}++;

    #
    # finish up
    #
    $Attrib->{$relDir}->set( $name, $attribInfo );
}


#
# helper functions for the wantedFiles subroutine
#
sub attributeWrite
{
    my ( $t, $dir, $attrib ) = @_;

    my $bpc      = $t->{bpc};
    my $Attrib   = $t->{Attrib};
    my $OutDir   = $t->{OutDir};

    if ( $Attrib->{$dir}->fileCount ) {
        my $data     = $attrib->writeData;
        my $fileName = $attrib->fileName("$OutDir/$dir");
        my $poolWrite =
            BackupPC::PoolWrite->new( $bpc, $fileName, length $data, $t->{compress} );
        $poolWrite->write( \$data );
    }
}


#
# Restore Routines
#
sub restore
{
    my ($t)      = @_;
    my $conf     = $t->{conf};
    my $fileList = $t->{fileList};

    my $view = $t->{view} =
      BackupPC::View->new( $t->{bpc}, $t->{bkupSrcHost}, $t->{backups} );
    $t->{hardLinkPoolFiles} = {};

    #
    # $t->{shareName}/$t->{pathHdrDest} is the disk destination.
    #
    ( my $targetDir = "$t->{shareName}/$t->{pathHdrDest}" ) =~ s{//+}{/}g;

    if ( !-d $targetDir ) {
        undef $@;
        eval { mkpath( $targetDir, 1, 0777 ); };
        if ($@) {
            $t->{_errStr} = "can't create restore directory $targetDir";
            return;
        }
    }
    $t->{targetDir} = $targetDir;

    my $i = 0;
    my $testFile;
    do {
        $i++;
        $testFile = "$targetDir/testFile.$$.$i";
    } while ( -e $testFile );

    my $fd;
    if ( !open $fd, ">", $testFile ) {
        $t->{_errStr} = "can't write to restore directory $targetDir";
        return;
    }
    close $fd;
    unlink $testFile;

    foreach my $ent (@$fileList) {

        if ( $ent =~ m{(^|/)\.\.(/|$)} || $ent !~ /^(.*)$/ ) {
            $t->logWrite("failed backup of top-level share element $ent\n");
            next;
        }

        $ent = "/" if $ent eq ".";
        $view->find( $t->{bkupSrcNum}, $t->{bkupSrcShare}, $ent, 0,
            sub { $t->restoreDirEnt(@_) },
        );
    }
}


#
# RESTORE HELPER FUNCTIONS
#
# Note: these are functions, and not methods. restoreDirEnt is a
# dispatcher for other file types.
#
sub restoreDirEnt
{
    my $t = shift @_;
    my ($fileAttrib) = @_;
    #print STDERR "\$t->restoreDirEnt($fileAttrib->{relPath})\n";
    ##print STDERR "\$fileAttrib = " . Dumper($fileAttrib);

    if ( $fileAttrib->{type} == BPC_FTYPE_DIR ) {
        $t->restoreDir($fileAttrib);

    } elsif ( $fileAttrib->{type} == BPC_FTYPE_FILE ) {
        $t->restoreFile($fileAttrib);

    } elsif ( $fileAttrib->{type} == BPC_FTYPE_HARDLINK ) {
        $t->restoreHardLink($fileAttrib);

    } elsif ( $fileAttrib->{type} == BPC_FTYPE_SYMLINK ) {
        $t->restoreSymlink($fileAttrib);

    } elsif ( $fileAttrib->{type} == BPC_FTYPE_CHARDEV
        || $fileAttrib->{type} == BPC_FTYPE_BLOCKDEV
        || $fileAttrib->{type} == BPC_FTYPE_FIFO ) {
        $t->restoreDevice($fileAttrib);

    } else {
        $t->logFileAction( "fail", $fileAttrib->{relPath}, $fileAttrib );
    }
}


sub restoreDir
{
    my $t           = shift @_;
    my ($dirAttrib) = @_;
    my $targetDir   = $t->{targetDir};
    #print STDERR "\$t->restoreDir(\$fileAttrib->{relPath})\n";

    ( my $dirPath = "$targetDir/$dirAttrib->{relPath}" ) =~ s{//+}{/}g;

    eval { mkpath( $dirPath, 1, $dirAttrib->{mode} ); };
    if ($@) {
        $t->logFileAction( "fail", $dirAttrib->{relPath}, $dirAttrib );
        #print STDERR "failed to create directory $dirAttrib->{relPath}\n";
    }
}


sub restoreFile
{
    my $t            = shift @_;
    my ($fileAttrib) = @_;
    my $targetDir    = $t->{targetDir};
    #print STDERR "\$t->restoreFile($fileAttrib->{relPath})\n";

    ( my $dst = "$targetDir/$fileAttrib->{relPath}" ) =~ s{//+}{/}g;
    my ( $dstfh, $data );

    my $f = BackupPC::FileZIO->open( $fileAttrib->{fullPath},
        0, $fileAttrib->{compress} );
    open $dstfh, ">", $dst;

    if ( !defined $dstfh || !defined $f ) {
        $t->logFileAction( "fail", $fileAttrib->{relPath}, $fileAttrib );
    }

    while ( $f->read( \$data, $BufSize ) > 0 ) {
        print $dstfh $data;
    }
    $t->logFileAction( "restore", $fileAttrib->{relPath}, $fileAttrib );
}


sub restoreHardLink
{
    my $t            = shift @_;
    my ($linkAttrib) = @_;
    my $targetDir    = $t->{targetDir};
    my $hardLinkRef  = $t->{hardLinkPoolFiles};
    #print STDERR "\$t->restoreHardLink($linkAttrib->{relPath})\n";

    my $poolFile = $linkAttrib->{fullPath};

    if ( defined $hardLinkRef->{$poolFile} ) {
        push @{ $hardLinkRef->{$poolFile} }, $linkAttrib;
    } else {
        $hardLinkRef->{$poolFile} = [$linkAttrib];
    }
}


sub restoreWriteHardLinks
{
    my $t         = shift @_;
    my $targetDir = $t->{targetDir};
    #print STDERR "\$t->restoreWriteHardLinks()\n";

    while ( my ( $poolFile, $fileList ) = each %{ $t->{hardLinkPoolFiles} } ) {

        next if ( @$fileList == 0 );
        my $firstFile = shift @$fileList;

        #
        # INCOMPLETE: recover this info & write.  May potentially
        # involve thrashing memory.
        #
        restoreWriteFile($firstFile);

        foreach (@$fileList) {
            link $firstFile, $_;
            $t->{fileCnt}++;
        }
    }
}


sub restoreSymlink
{
    my $t            = shift @_;
    my ($linkAttrib) = @_;
    my $targetDir    = $t->{targetDir};
    #print STDERR "\$t->restoreSymlink($linkAttrib->{relPath})\n";

    ( my $dst = "$targetDir/$linkAttrib->{relPath}" ) =~ s{//+}{/}g;
    my ( $data, $prefixMatches, $targetFields );

    my $l = BackupPC::FileZIO->open( $linkAttrib->{fullPath},
        0, $linkAttrib->{compress} );

    if ( !defined $l || $l->read( \$data, $BufSize ) < 0 ) {

        $t->logFileAction( "fail", $linkAttrib->{relPath}, $linkAttrib );
        $l->close() if defined $l;
        return;
    }

    my $symTarget = $data;
    while ( $l->read( \$data, $BufSize ) > 0 ) {
        $symTarget .= $data;
    }

    if ( !defined $t->{targetDirPrefixes} ) {

        ( my $fieldSplit = $targetDir ) =~ s{^/+}{};
        my $targetFields = [ split '/', $fieldSplit ];
        do {
            push @$prefixMatches, join( '/', @$targetFields );
        } while ( shift @$targetFields );
        $t->{targetDirPrefixes} = map { qr{^/?$_/?/}; } @$prefixMatches;
    }
    $prefixMatches = $t->{targetDirPrefixes};

    foreach my $prefix (@$prefixMatches) {
        last if $symTarget =~ s/$prefix/$targetDir/;
    }
    symlink $symTarget, $dst;

    $t->logFileAction( "restore", $linkAttrib->{relPath}, $linkAttrib );
}


sub restoreDevice
{
    my $t           = shift @_;
    my ($devAttrib) = @_;
    my $targetDir   = $t->{targetDir};
    #print STDERR "\$t->restoreDevice($devAttrib->{relPath})\n";

    my ( $devmajor, $devminor );
    my $d = BackupPC::FileZIO->open( $devAttrib->{fullPath},
        0, $devAttrib->{compress} );
    my $data;

    if ( !defined($d) || $d->read( \$data, $BufSize ) < 0 ) {

        $t->logFileAction( "fail", $devAttrib->{relPath}, $devAttrib );
        $d->close() if ( defined $d );
        return;
    }
    $d->close();
    if ( $data =~ /(\d+),(\d+)/ ) {
        $devmajor = $1;
        $devminor = $2;
        $t->restoreWriteDevice( $devAttrib, $devmajor, $devminor )
          or $t->logFileAction( "fail", $devAttrib->{relPath}, $devAttrib );

    } else {
        $t->restoreWriteDevice($devAttrib)
          or $t->logFileAction( "fail", $devAttrib->{relPath}, $devAttrib );
    }
}


sub restoreWriteDevice
{
    my $t         = shift @_;
    my $devAttrib = shift @_;
    my ( $maj, $min ) = @_ || ( undef, undef );
    my $targetDir = $t->{targetDir};
    #print STDERR "\$t->restorewriteDevice($devAttrib->{relPath}, $maj, $min)";

    my $umask = $t->{conf}->{UmaskMode};
    my $mode  = $devAttrib->{mode};

    ( my $dst = "$targetDir/$devAttrib->{relPath}" ) =~ s{//+}{/}g;

    if ($UnixMknodOK) {
        mknod( $dst, ( $mode | $umask ), makedev( $maj, $min ) );

    } else {
        if ( defined $maj && defined $min ) {
            system split /\s/, "/bin/mknod $dst $maj $min";
        } else {
            system split /\s/, "/usr/bin/mkfifo $dst";
        }
        system( "/bin/chmod", ( $mode | $umask ), $dst );
    }
}


sub logFileAction
{
    my ( $t, $action, $name, $st ) = @_;
    my ( $owner, $fileAction );

    if ( ref $st eq "File::stat" ) {

        $owner      = "$st->uid/$st->gid";
        $fileAction = sprintf
          "  %-6s %1s%4o %9s %11.0f %s\n",
          $action, S_IFMT( $st->mode ), S_IMODE( $st->mode ),
          $owner, $st->size, $name;

    } else {
        #
        # $st is a BackupPC::Attrib fileAttrib array.
        #
        $owner      = "$st->{uid}/$st->{gid}";
        $fileAction = sprintf
          "  %-6s %1s%4o %9s %11.0f %s\n",
          $action, $st->{type}, $st->{mode},
          $owner,  $st->{size}, $st->{relPath};
    }

    return $t->logWrite( $fileAction, 1 );
}


1;
