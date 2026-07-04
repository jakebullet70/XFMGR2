xcplz.prg - A Commander X16 program to uncompress archives compressed with 
            my X16 proprietary LZ16 format ! xcplz will also extract standard 
            Unix CPIO type archives with the "newc" header format. 
            (magic header # 070701) If a cpio archive is the LZ16 compressed 
            file it will be extracted upon decompression finishing. 

MAKECPLZ - Desktop (Windows/Linux) executable to create LZ16 compressed files. 
           CPIO archives can be created with standard OS commands.  But 
           MAKECPLZ will execute the proper system command to make a cpio
           archive with the "newc" header format, compatible with "xcplz.prg"
           and then compress it !

           MAKECPLZ also creates the LZ16 compressed file.  To do this is it
           needs the "lzsa" compression utility installed and in your system
           path.  

           lzsa can be downloaded from: https://github.com/emmanuel-marty/lzsa


MAKECPLZ Command line usage
---------------------------

  MAKECPLZ FILENAME - Compress's FILENAME and outputs a FILENAME.LZ16 
                      compressed file. (requires lzsa installed)

MAKECPLZ FOLDERNAME - Creates a compatible "newc" cpio file from FOLDER
                      and then compress's it to an LZ16 file (if lzsa found)

  Optional command parameter CS=ChunkSize  Where ChunkSize is a number from 
  4096 to 60416 and signifies the UNCOMPRESSED Data chunk size to use for the
  LZ16 file.   This value defaults to 45000 bytes.  

  MAKECPLZ FILENAME CS=12500   (Use a Chunksize of 12500 bytes) 

  The supported CPIO archive format is an older "tar like" standard and is
  documented elsewhere.  The following standard system commands can create
  the proper format  "ONLY THE NEWC HEADER FORMAT" IS SUPPORTED BY xcplz.prg
  
 On a system with a BSD tar version (Includes Windows tar & MACOS)

  tar.exe -cf archive.cpio --format=newc "C:\Path\To\Your\Folder"

 On a system with GNU tar (Linux !) 

  find PATH/* -depth -print0 | cpio -o -H newc --null > /path/to/archive.cpio

You can install BSDTAR on a Linux system and use bsdtar like you would on
Windows or MACOS (or other BSD).  In this case the command will be bsdtar 
instead of just tar.

MAKECPLZ has the proper command syntax embedded depending on what system 
it is compiled for !

For a run down of the LZ16 Compressed format see the file 
  LZ16-COMPRESSED-FORMAT.TXT




