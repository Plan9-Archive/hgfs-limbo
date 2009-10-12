implement HgIdentify;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
include "string.m";
	str: String;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "mercurial.m";
	hg: Mercurial;
	Dirstate, Dirstatefile, Revlog, Repo, Change, Manifest, Manifestfile, Entry, Tag: import hg;
include "util0.m";
	util: Util0;
	join, readfile, l2a, inssort, warn, fail: import util;

HgIdentify: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	hg = load Mercurial Mercurial->PATH;
	hg->init();

	hgpath := "";

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	(repo, err) := Repo.find(hgpath);
	if(err != nil)
		fail(err);

	ds: ref Dirstate;
	(ds, err) = repo.dirstate();
	if(err != nil)
		fail("dirstate: "+err);
	if(ds.p2 != hg->nullnode)
		fail("checkout has two parents, is in merge, refusing to update");

	branch: string;
	(branch, err) = repo.workbranch();
	if(err != nil)
		fail(err);

	tags: list of ref Tag;
	(tags, err) = repo.revtags(ds.p1);
	if(err != nil)
		fail(err);
	revtags: list of string;
	for(l := tags; l != nil; l = tl l)
		revtags = (hd l).name::revtags;
	revtags = util->rev(revtags);

	# xxx should show + after nodeid when local modifications exist, and probably multiple parents too, somehow.
	# xxx should we use branch and tag of ds.p2 too?
	s := ds.p1[:12];
	if(branch != "default")
		s += sprint(" (%s)", branch);
	if(revtags != nil)
		s += " "+join(revtags, "/");
	sys->print("%s\n", s);
}
