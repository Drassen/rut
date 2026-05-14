#!/bin/sh

## @meta-description@EuroNavV Data Upload

do_exit() {
    echo $1
    exit 1
}

move_files_in_dir() {
    SRC=$1
    DST=$2

    test -d "$SRC/" || return 0

    OLDDIR="$PWD"
    cd $SRC
    find . -type f |
    (
	while read a ; do 
	    FILE=$(echo $a | sed -e 's#.*/\([^/]*\)$#\1#')
	    DIR=$(echo $a | sed -e 's#\(.*\)/[^/]*$#\1#')
	    echo "Moving $SRC/$DIR/$FILE to $DST/$DIR/$FILE"
	    mkdir -p "$DST/$DIR"
	    mv "$SRC/$DIR/$FILE" "$DST/$DIR/$FILE"
	done
    )
    cd "$OLDDIR"
}

top_half() {
    TEMP=/mnt/$TARGET/tmp
    rm -Rf $TEMP
    mkdir $TEMP
    for ARCHIVE in /db/external-device/*.tgz ; do
	if test -e "$ARCHIVE" ; then
	    echo "Extracting $ARCHIVE to $TEMP"
	    tar -xz -f "$ARCHIVE" -C "$TEMP" || do_exit "Extracting $ARCHIVE failed!"
	fi
    done
}

bottom_half() {
    TEMP=/mnt/$TARGET/tmp
    MEDIA=/mnt/$TARGET

    for root in settings macros screenshots SQL userAttachments res pictures; do
	move_files_in_dir $TEMP/db/$root $MEDIA/db/$root
    done
    sync

    # Move maps
    for maptype in raster vector terrain ; do
	if test -d "$TEMP/db/$maptype/" ; then
	    mkdir -p $MEDIA/db/$maptype
	    for map in "$TEMP/db/$maptype/"* ; do
		if test -e "$map" ; then
		    MAPNAME=$(echo "$map" | sed -e "s#$TEMP/db/$maptype/##")
		    TARGETMAP="$MEDIA/db/$maptype/$MAPNAME"
		    echo "Moving $map to $TARGETMAP"
		    test -d "$TARGETMAP" && mv "$TARGETMAP" "$map.old"
		    mv "$map" "$TARGETMAP"
		fi
	    done
	fi
    done

    rm -Rf $TEMP &
    # sync en5.db
    
    # Create en5.db
    echo "Syncing en5.db"
    mkdir -p /tmp/tmpdb
    ( cat $MEDIA/db/SQL/scripts/En5Db.createdb.sql $MEDIA/db/SQL/scripts/*.create.sql ) | \
	dbtool --with-db-root /tmp/tmpdb --without-time --execsql /proc/self/fd/0 >/dev/null 2>&1
    mv /tmp/tmpdb/en5.db $MEDIA/db/en5.db
    rm -Rf /tmp/tmpdb
    wait
}

# init
busybox-install >/dev/null 2>&1

test -d /db/external-device/ || do_exit 'Directory /db/external-device/ does not exist!'
test -e /db/external-device/target || do_exit 'Target media file not found!'
. /db/external-device/target

if test -n "$EAMIniContent" ; then
    for target in pcmciaA hd2 hd1 doc ; do
        test -e "/mnt/$target/db/EuroNavMedia.ini" && grep -q "^$EAMIniContent\$" "/mnt/$target/db/EuroNavMedia.ini" && TARGET=$target
    done
fi

test -z "$TARGET" && do_exit "No target media found or provided!"

if test -z "$1" ; then
    test -f "/mnt/$TARGET/db/lock" && echo "Warning: Target '$TARGET' is locked. Continuing."
    # lock media
    echo "Updating from external media." >/mnt/$TARGET/db/lock
    top_half
    sync
    echo "Update: First stage finished."
    exit 42
fi

if test "$1" = "finish" ; then
    test ! -f "/mnt/$TARGET/db/lock" && do_exit "Target media '$TARGET' not locked!"
    bottom_half
    sync
    # unlock media
    rm -f /mnt/$TARGET/db/lock
    sync
    echo "Update: Second stage finished."
fi
