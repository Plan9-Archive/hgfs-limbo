implement HgCommit;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "daytime.m";
	daytime: Daytime;
include "readdir.m";
	readdir: Readdir;
include "string.m";
	str: String;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "filter.m";
	deflate: Filter;
include "filtertool.m";
	filtertool: Filtertool;
include "mercurial.m";
	hg: Mercurial;
	Transact, Dirstate, Dsfile, Revlog, Repo, Change, Manifest, Mfile, Entry: import hg;
include "util0.m";
	util: Util0;
	readfd, rev, join, readfile, l2a, inssort, warn, fail: import util;

HgCommit: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};


dflag: int;
vflag: int;
repo: ref Repo;
hgpath := "";
msg: string;
tr: ref Transact;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->open("/dev/null", Sys->OREAD);
	daytime = load Daytime Daytime->PATH;
	readdir = load Readdir Readdir->PATH;
	str = load String String->PATH;
	tables = load Tables Tables->PATH;
	util = load Util0 Util0->PATH;
	util->init();
	deflate = load Filter Filter->DEFLATEPATH;
	deflate->init();
	filtertool = load Filtertool Filtertool->PATH;
	hg = load Mercurial Mercurial->PATH;
	hg->init(0);

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-h path] [-v] [-m msg] [path ...]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	hg->debug = dflag++;
		'h' =>	hgpath = arg->earg();
		'v' =>	vflag++;
		'm' =>	msg = arg->earg();
			if(msg == nil)
				arg->usage();
		* =>	arg->usage();
		}
	args = arg->argv();

	{ init0(args); }
	exception e {
	"hg:*" =>
		if(tr != nil)
			repo.xrollback(tr);
		fail(e[3:]);
	}
}

init0(args: list of string)
{
	repo = Repo.xfind(hgpath);
	root := repo.workroot();

	user := hg->xreaduser(repo);
	now := daytime->now();
	tzoff := daytime->local(now).tzoff;
	say(sprint("have user %q, now %d, tzoff %d", user, now, tzoff));

	ds := hg->xdirstate(repo, 0);

	r: list of ref Dsfile;
	pathtab := Strhash[ref Dsfile].new(31, nil);
	if(args == nil)
		r = inspect(r, ds.l, pathtab, nil);
	else
		for(; args != nil; args = tl args)
			r = inspect(r, ds.findall(hd args, 0), pathtab, hd args);
	if(r == nil)
		error("no changes");

	ochrev := repo.xlastrev();
	link := ochrev+1;

	m1 := repo.xmanifest(ds.p1);
	m2 := repo.xmanifest(ds.p2);
	m := manifestmerge(m1, m2);

	say(sprint("newrev and link is %d, changes p1 %s p2 %s, manifest p1 %s p2 %s", link, ds.p1, ds.p2, m1.nodeid, m2.nodeid));

	if(msg == nil) {
		warn("message:");
		msg = string readfd(sys->fildes(0), -1);
		say(sprint("msg is %q", msg));
		if(msg == nil)
			error("empty commit message, aborting");
	}

	tr = repo.xtransact();

	files := l2a(r);
	inssort(files, pathge);
	filenodeids := array[len files] of string;
	modfiles: list of string;
	nds := ref Dirstate (1, hg->nullnode, hg->nullnode, ds.l, nil);
	for(i := 0; i < len files; i++) {
		dsf := files[i];
		path := dsf.path;
		say("handling "+dsf.text());
		m.del(path);
		case dsf.state {
		hg->STremove =>
			modfiles = path::modfiles;
			nds.del(path);
			continue;
		hg->STadd or
		hg->STneedmerge or
		hg->STnormal =>
			;
		* =>
			raise "other state?";
		}

		f := root+"/"+path;
		buf := readfile(f, -1);
		if(buf == nil)
			error(sprint("open %q: %r", f));
		(ok, dir) := sys->stat(f);
		if(ok != 0)
			error(sprint("stat %q: %r", f));

		fp1 := fp2 := hg->nullnode;
		if((mf1 := m1.find(path)) != nil)
			fp1 = mf1.nodeid;
		if((mf2 := m2.find(path)) != nil)
			fp2 = mf2.nodeid;

		rl := repo.xopenrevlog(path);

		nodeid := hg->xcreatenodeid(buf, fp1, fp2);
		if(rl.xfindnodeid(nodeid, 0) != nil)
			continue;

		say(sprint("adding to revlog for file %#q, fp1 %s, fp2 %s", path, fp1, fp2));
		ne := rl.xappend(repo, tr, nodeid, fp1, fp2, link, buf);
		filenodeids[i] = ne.nodeid;
		say(sprint("file now at nodeid %s", ne.nodeid));

		mf := ref Mfile (path, dir.mode&8r777, ne.nodeid, 0);
		m.add(mf);
		modfiles = path::modfiles;

		dsf.state = hg->STnormal;
		dsf.size = int dir.length;
		dsf.mtime = dir.mtime;
	}

	say("adding to manifest");
	ml := repo.xmanifestlog();
	mbuf := m.xpack();
	mnodeid := hg->xcreatenodeid(mbuf, m1.nodeid, m2.nodeid);
	if(ml.xfindnodeid(mnodeid, 0) == nil)
		ml.xappend(repo, tr, mnodeid, m1.nodeid, m2.nodeid, link, mbuf);

	say("adding to changelog");
	cl := repo.xchangelog();
	cmsg := sprint("%s\n%s\n%d %d\n%s\n\n%s", mnodeid, user, now, tzoff, join(rev(modfiles), "\n"), msg);
	say(sprint("change message:"));
	say(cmsg);
	cbuf := array of byte cmsg;
	cnodeid := hg->xcreatenodeid(cbuf, ds.p1, ds.p2);
	nheads := len repo.xheads();
	ce := cl.xappend(repo, tr, cnodeid, ds.p1, ds.p2, link, cbuf);
	nnheads := len repo.xheads()-nheads;

	nds.p1 = ce.nodeid;
	repo.xwritedirstate(nds);
	repo.xcommit(tr);
	if(nnheads != 0)
		warn("created new head");
}

inspect(r, l: list of ref Dsfile, tab: ref Strhash[ref Dsfile], path: string): list of ref Dsfile
{
	n := 0;
	for(; l != nil; l = tl l) {
		dsf := hd l;
		if(tab.find(dsf.path) != nil)
			continue;
say("inspect: "+dsf.text());
		case dsf.state {
		hg->STuntracked =>
			continue;
		hg->STnormal or
		hg->STneedmerge =>
			if(dsf.state == hg->STnormal && dsf.size >= 0)
				continue;
			warn(sprint("M %q", dsf.path));
		hg->STremove =>
			warn(sprint("R %q", dsf.path));
		hg->STadd =>
			warn(sprint("A %q", dsf.path));
		}

		tab.add(dsf.path, dsf);
		r = dsf::r;
		n++;
	}
	if(n == 0 && path != nil)
		warn(sprint("%q: no matches", path));
	return r;
}

manifestmerge(m1, m2: ref Manifest): ref Manifest
{
	l: list of ref Mfile;
	i1 := i2 := 0;
	for(;;) {
		if(i1 < len m1.files)
			p1 := (f1 := m1.files[i1]).path;
		if(i2 < len m2.files)
			p2 := (f2 := m2.files[i2]).path;
		if(p1 == p2) {
			if(p1 == nil)
				break;
			l = ref *f1::l;
			i1++;
			i2++;
		} else if(p2 == nil || p1 < p2) {
			l = ref *f1::l;
			i1++;
		} else {
			l = ref *f2::l;
			i2++;
		}
	}
	return ref Manifest (nil, l2a(rev(l)));
}

pathge(a, b: ref Dsfile): int
{
	return a.path >= b.path;
}

error(s: string)
{
	raise "hg:"+s;
}

say(s: string)
{
	if(dflag)
		warn(s);
}
