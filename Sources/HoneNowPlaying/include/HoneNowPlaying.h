#ifndef HoneNowPlaying_h
#define HoneNowPlaying_h

/// Entry point of the "now playing" adapter. Shaped like a Perl XSUB so that
/// `DynaLoader::dl_install_xsub` can call it from /usr/bin/perl (the two
/// arguments are Perl's interpreter and CV; both are ignored). Never returns.
/// See HoneNowPlaying.m for the stdout/stdin protocol.
void hone_np_stream(void *perl, void *cv);

#endif
