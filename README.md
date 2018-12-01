Description
===========

Perl script for listing & unpacking .mht / .mhtml files (MIME-encoded HTML archives).

Based on 'unmht' (http://www.volkerschatz.com/unix/uware/unmht.html).

Usage
=====

`mhtml-tool [ -l | --list | -o <dir/ or name> | --output <dir/ or name> ] <MHT file>`

By default, unpacks an MHTML archive (an archive type saved by some browsers) to the
current directory.  The first HTML file in the archive is taken for the primary web page,
and all other contained files are written to a directory named after that HTML file.

Options:

-l, --list    List archive contents (file name, MIME type, size and URL)

-o, --output  Unpack to directory <dir/> or to file <name>.html
