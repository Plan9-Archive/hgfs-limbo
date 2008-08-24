implement HgFs;

# todo
# - generate lengths for repo files
# - generate mtime for repo files
# - show parents of a revision?
# - cache results, for revtrees and files
# - keep track of gens for dir, and cache them

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "daytime.m";
	daytime: Daytime;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator, Navop: import styxservers;
include "filter.m";
	deflate: Filter;
	Rq: import Filter;
include "tables.m";
	tables: Tables;
	Table: import tables;
include "lists.m";
	lists: Lists;
include "mercurial.m";
	mercurial: Mercurial;
	Revlog, Repo, Nodeid, Change, Manifest, Manifestfile: import mercurial;


Dflag, dflag: int;
vflag: int;

Qroot, Qlastrev, Qfiles, Qlog, Qtgz, Qrepofile, Qlogrev, Qtgzrev: con iota;
tab := array[] of {
	(Qroot,		"xxx",		Sys->DMDIR|8r555),
	(Qlastrev,	"lastrev",	8r444),
	(Qfiles,	"files",	Sys->DMDIR|8r555),
	(Qlog,		"log",		Sys->DMDIR|8r555),
	(Qtgz,		"tgz",		Sys->DMDIR|8r555),
	(Qrepofile,	"<repofile>",	8r555),
	(Qlogrev,	"<logrev>",	8r444),
	(Qtgzrev,	"<tgzrev>",	8r444),
};

# Qrepofiles are the individual files in a particular revision.
# qids for files in a revision are composed of:
# 8 bits qtype
# 24 bits manifest file generation number (<<8)
# 24 bits revision (<<32)
# when opening a revision, the file list in the revlog manifest is parsed,
# and a full file tree (only path names) is created.  gens are assigned
# incrementally, the root dir has gen 0.  Qtgz and Qlog always have gen 0.
# this ensures qids are permanent for a repository.

srv: ref Styxserver;
repo: ref Repo;
reponame: string;
starttime: int;
tgztab: ref Table[ref Tgz];

HgFs: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	styx = load Styx Styx->PATH;
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	styxservers->init(styx);
	daytime = load Daytime Daytime->PATH;
	deflate = load Filter Filter->DEFLATEPATH;
	deflate->init();
	tables = load Tables Tables->PATH;
	lists = load Lists Lists->PATH;
	mercurial = load Mercurial Mercurial->PATH;
	mercurial->init();

	hgpath := "";

	sys->pctl(Sys->NEWPGRP, nil);

	arg->init(args);
	arg->setusage(arg->progname()+" [-Ddv] [-h path]");
	while((c := arg->opt()) != 0)
		case c {
		'D' =>	Dflag++;
			styxservers->traceset(Dflag);
		'd' =>	dflag++;
			if(dflag > 1)
				mercurial->debug++;
		'v' =>	vflag++;
		'h' =>	hgpath = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	starttime = daytime->now();

	err: string;
	(repo, err) = Repo.find(hgpath);
	if(err != nil)
		fail(err);
	say("found repo");

	reponame = repo.name();
	tab[Qroot].t1 = reponame;
	tgztab = tgztab.new(32, nil);

	navch := chan of ref Navop;
	spawn navigator(navch);

	nav := Navigator.new(navch);
	msgc: chan of ref Tmsg;
	(msgc, srv) = Styxserver.new(sys->fildes(0), nav, big Qroot);

done:
	for(;;) alt {
	gm := <-msgc =>
		if(gm == nil)
			break;
		pick m := gm {
		Readerror =>
			warn("read error: "+m.error);
			break done;
		}
		dostyx(gm);
	}
}

dostyx(gm: ref Tmsg)
{
	pick m := gm {
	Open =>
		(fid, mode, nil, err) := srv.canopen(m);
		if(fid == nil)
			return replyerror(m, err);
		q := int fid.path&16rff;
		id := int fid.path>>8;
		# xxx accounting?

		srv.default(m);

	Read =>
		f := srv.getfid(m.fid);
		if(f.qtype & Sys->QTDIR) {
			# pass to navigator, to readdir
			srv.default(m);
			return;
		}
		say(sprint("read f.path=%bd", f.path));
		q := int f.path&16rff;

		case q {
		Qlastrev =>
			(rev, err) := repo.lastrev();
			if(err != nil)
				return replyerror(m, err);
			srv.reply(styxservers->readstr(m, sprint("%d", rev)));

		Qlogrev =>
			(rev, nil) := revgen(f.path);
			(change, err) := repo.change(rev);
			if(err != nil)
				return replyerror(m, err);
			srv.reply(styxservers->readstr(m, change.text()));

		Qtgzrev =>
			(rev, nil) := revgen(f.path);

			tgz := tgztab.find(f.fid);
			if(tgz == nil) {
				if(m.offset != big 0)
					return replyerror(m, "random reads on .tgz's not supported");

				err: string;
				(tgz, err) = Tgz.new(rev);
				if(err != nil)
					return replyerror(m, err);
				tgztab.add(f.fid, tgz);
			}
			(buf, err) := tgz.read(m.count, m.offset);
			if(err != nil)
				return replyerror(m, err);
			srv.reply(ref Rmsg.Read(m.tag, buf));

		Qrepofile  =>
			(rev, gen) := revgen(f.path);
			(r, err) := treeget(rev);

			d: array of byte;
			if(err == nil)
				(d, err) = r.read(gen);
			if(err != nil)
				return replyerror(m, err);
			srv.reply(styxservers->readbytes(m, d));

		* =>
			replyerror(m, styxservers->Eperm);
		}

	Clunk or Remove =>
		f := srv.getfid(m.fid);
		q := int f.path&16rff;

		case q {
		Qtgzrev =>
			tgztab.del(f.fid);
		}
		srv.default(gm);

	* =>
		srv.default(gm);
	}
}

navigator(c: chan of ref Navop)
{
again:
	for(;;) {
		navop := <-c;
		q := int navop.path&16rff;
		(rev, gen) := revgen(navop.path);
		say(sprint("have navop, tag %d, q %d, rev %d, gen %d", tagof navop, q, rev, gen));

		pick op := navop {
		Stat =>
			say("stat");
			case q {
			Qrepofile =>
				(r, err) := treeget(rev);
				say(sprint("navigator, stat, op.path %bd, rev %d, gen %d", op.path, rev, gen));
				d: ref Sys->Dir;
				if(err == nil)
					(d, err) = r.stat(gen);
				op.reply <-= (d, err);
			* =>
				op.reply <-= (dir(op.path), nil);
			}

		Walk =>
			say(sprint("walk, name %q", op.name));

			# handle repository files first, other are handled below
			case q {
			Qrepofile =>
				(r, err) := treeget(rev);
				d: ref Sys->Dir;
				if(err == nil)
					(d, err) = r.walk(gen, op.name);
				op.reply <-= (d, err);
				continue again;
			}

			if(op.name == "..") {
				nq: int;
				case q {
				Qlogrev =>
					nq = Qlog;
				Qtgzrev =>
					nq = Qtgz;
				Qroot or Qlastrev or Qfiles or Qlog or Qtgz =>
					nq = Qroot;
				* =>
					raise sprint("unhandled case in walk .., q %d", q);
				}
				op.reply <-= (dir(big nq), nil);
				continue again;
			}

			case q {
			Qroot =>
				for(i := Qlastrev; i <= Qtgz; i++)
					if(tab[i].t1 == op.name) {
						op.reply <-= (dir(big tab[i].t0), nil);
						continue again;
					}
				op.reply <-= (nil, styxservers->Enotfound);

			Qfiles =>
				rev: int;
				err: string;
				if(op.name == "last")
					(rev, err) = repo.lastrev();
				else
					(rev, err) = parserev(op.name);
				if(err != nil) {
					op.reply <-= (nil, err);
					continue again;
				}
				(change, manifest, merr) := repo.manifest(rev);
				if(merr != nil) {
					op.reply <-= (nil, merr);
					continue again;
				}

				say("walk to files/<rev>/");
				(r, rerr) := treeget(rev);
				if(rerr != nil)
					op.reply <-= (nil, rerr);
				else
					op.reply <-= r.stat(0);

			Qlog =>
				rev: int;
				err: string;
				if(op.name == "last")
					(rev, err) = repo.lastrev();
				else
					(rev, err) = parserev(op.name);

				if(err != nil) {
					op.reply <-= (nil, err);
					continue again;
				}

				op.reply <-= (dir(child(q)|big rev<<32), nil);

			Qtgz =>
				# check for reponame-rev.tgz
				if(!str->prefix(reponame+"-", op.name) || !suffix(".tgz", op.name)) {
					op.reply <-= (nil, styxservers->Enotfound);
					continue again;
				}
				revstr := op.name[len reponame+1:len op.name-len ".tgz"];
				(tgzrev, err) := parserev(revstr);
				if(err != nil) {
					op.reply <-= (nil, err);
					continue again;
				}
					
				op.reply <-= (dir(child(q)|big tgzrev<<32), nil);

			* =>
				raise sprint("unhandled case in walk %q, from %d", op.name, q);
			}

		Readdir =>
			say("readdir");
			case q {
			Qroot =>
				n := Qtgz+1-Qlastrev;
				have := 0;
				for(i := 0; have < op.count && op.offset+i < n; i++) {
					op.reply <-= (dir(big (Qlastrev+i)), nil);
					have++;
				}
			Qfiles or Qlog or Qtgz =>
				if(op.offset == 0 && op.count > 0) {
					(npath, err) := last(q);
					if(err != nil) {
						op.reply <-= (nil, err);
						continue again;
					}
					d := dir(npath);
					if(q == Qfiles || q == Qlog)
						d.name = "last";
					op.reply <-= (d, nil);
				}

			Qrepofile =>
				(r, err) := treeget(rev);
				if(err != nil) {
					op.reply <-= (nil, err);
					continue again;
				} else
					r.readdir(gen, op);

			* =>
				raise sprint("unhandled case for readdir %d", q);
			}

			op.reply <-= (nil, nil);
		}
	}
}

revgen(path: big): (int, int)
{
	rev := int (path>>32) & 16rffffff;
	gen := int (path>>8) & 16rffffff;
	return (rev, gen);
}

last(q: int): (big, string)
{
	(rev, err) := repo.lastrev();
	if(err != nil)
		return (big 0, err);

	nq: int;
	case q {
	Qfiles => 	nq = Qrepofile;
	Qlog =>		nq = Qlogrev;
	Qtgz =>		nq = Qtgzrev;
	* =>		raise sprint("bogus call 'last' on q %d", q);
	}
	return (big nq|big rev<<32, nil);
}

child(q: int): big
{
	case q {
	Qfiles =>	return big Qrepofile;
	Qlog =>		return big Qlogrev;
	Qtgz =>		return big Qtgzrev;
	* =>	raise sprint("bogus call 'child' on q %d", q);
	}
}

parserev(s: string): (int, string)
{
	if(s == "0")
		return (0, nil);
	if(str->take(s, "0") != "")
		return (0, "bogus leading zeroes");
	(rev, rem) := str->toint(s, 10);
	if(rem != nil)
		return (0, "bogus trailing characters after revision");
	return (rev, nil);
}

dir(path: big): ref Sys->Dir
{
	q := int path&16rff;
	(rev, gen) := revgen(path);
	(nil, name, perm) := tab[q];
	say(sprint("dir, path %bd, name %q", path, name));

	d := ref sys->zerodir;
	d.name = name;
	if(q == Qlogrev)
		d.name = sprint("%d", rev);
	if(q == Qtgzrev)
		d.name = sprint("%s-%d.tgz", reponame, rev);
	d.uid = d.gid = "hg";
	d.qid.path = path;
	if(perm&Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mtime = d.atime = 0;  # xxx
	d.mode = perm;
	say("dir, done");
	return d;
}

replyerror(m: ref Tmsg, s: string)
{
	srv.reply(ref Rmsg.Error(m.tag, s));
}


treeget(rev: int): (ref Revtree, string)
{
	(nil, manifest, err) := repo.manifest(rev);
	if(err != nil)
		return (nil, err);
	r := Revtree.new(manifest, rev);
	return (r, nil);
}


# file in a revtree
File: adt {
	gen:	int;
	path:	string;
	nodeid:	ref Nodeid;	# nil for directories
	length:	big;	# -1 => not yet valid
	data:	array of byte;	# only for plain files.  nil if not yet valid.
	opens:	int;	# ref count

	new:	fn(gen: int, path: string, nodeid: ref Nodeid): ref File;
	isdir:	fn(f: self ref File): int;
	mode:	fn(f: self ref File): int;
	text:	fn(f: self ref File): string;
};

File.new(gen: int, path: string, nodeid: ref Nodeid): ref File
{
	return ref File(gen, path, nodeid, big -1, nil, 0);
}

File.isdir(f: self ref File): int
{
	return f.nodeid == nil;
}

File.mode(f: self ref File): int
{
	if(f.isdir())
		return 8r555|Sys->DMDIR;
	return 8r444;
}

File.text(f: self ref File): string
{
	return sprint("<file gen %d, path %q, nodeid %s, length %bd, data nil %d, opens %d>", f.gen, f.path, f.nodeid.text(), f.length, f.data == nil, f.opens);
}


# all paths of a tree of a single revision
Revtree: adt {
	rev:	int;
	tree:	array of ref File;
	opens:	int;

	new:	fn(mf: ref Manifest, rev: int): ref Revtree;
	readdir:	fn(r: self ref Revtree, gen: int, op: ref Navop.Readdir);
	read:	fn(r: self ref Revtree, gen: int): (array of byte, string);
	stat:	fn(r: self ref Revtree, gen: int): (ref Sys->Dir, string);
	walk:	fn(r: self ref Revtree, gen: int, name: string): (ref Sys->Dir, string);
};

gendirs(prevdir: string, gen: int, path: string): (string, int, list of ref File)
{
	(path, nil) = str->splitstrr(path, "/");
	if(path == nil)
		return (prevdir, gen, nil);

	if(path[len path-1] != '/')
		raise "wuh?";
	path = path[:len path-1];
	if(str->prefix(path, prevdir))
		return (prevdir, gen, nil);

	dirs: list of ref File;
	s: string;
	for(el := sys->tokenize(path, "/").t1; el != nil; el = tl el) {
		s += "/"+hd el;
		if(str->prefix(s[1:], prevdir))
			continue;  # already present
		dirs = File.new(gen++, s[1:], nil)::dirs;
	}

	return (path, gen, dirs);
}

Revtree.new(mf: ref Manifest, rev: int): ref Revtree
{
	say("revtree.new");
	prevdir: string;  # previous dir we generated

	gen := 0;
	r := File.new(gen++, "", nil)::nil;
	for(l := mf.files; l != nil; l = tl l) {
		m := hd l;
		(nprevdir, ngen, dirs) := gendirs(prevdir, gen, m.path);
		(prevdir, gen) = (nprevdir, ngen);
		r = lists->concat(dirs, r);
		r = File.new(gen++, m.path, m.nodeid)::r;
	}
	rt := ref Revtree (rev, l2a(lists->reverse(r)), 0);
	say(sprint("revtree.new done, have %d paths:", len r));
	for(i := 0; i < len rt.tree; i++)
		say(sprint("\t%s", rt.tree[i].text()));
	say("eol");
	return rt;
}

dirfiles(r: ref Revtree, gen: int): array of int
{
	bf := r.tree[gen];
	a := array[len r.tree-gen] of int; # max possible length
	path := bf.path;
	if(path != nil)
		path = "/"+path;
	have := 0;
	prevelem: string;
	for(i := gen; i < len r.tree; i++) {
		p := "/"+r.tree[i].path;
		say(sprint("checking %q against %q", path, p));
		if(str->prefix(path+"/", p) && !has(p[len path+1:], '/')) {
			elem := p[len path+1:];
			if(elem != nil && elem != prevelem) {
				say(sprint("adding gen %d", i));
				a[have++] = i;
				prevelem = elem;
			}
		}
	}
	a = a[:have];
	say(sprint("dirfiles, have %d elems", len a));
	return a;
}

Revtree.readdir(r: self ref Revtree, gen: int, op: ref Navop.Readdir)
{
	f := r.tree[gen];
	say(sprint("revtree.readdir, for %s", f.text()));
	# xxx handle case for f.length == -1

	# xxx cache this result
	gens := dirfiles(r, gen);

	say(sprint("revtree.readdir, len gens %d, op.count %d, op.offset %d", len gens, op.count, op.offset));
	have := 0;
	for(i := 0; have < op.count && op.offset+i < len gens; i++) {
		(d, err) := r.stat(gens[i]);
		op.reply <-= (d, err);
		if(err != nil)
			return say("revtree.readdir, stopped after error: "+err);
		have++;
	}
	say(sprint("revtree.readdir done, have %d, i %d", have, i));
}

Revtree.walk(r: self ref Revtree, gen: int, name: string): (ref Sys->Dir, string)
{
	f := r.tree[gen];
	say(sprint("revtree.walk, name %q, file %s", name, f.text()));
	npath := f.path;
	if(name == "..") {
		if(gen == 0)
			return (dir(big Qfiles), nil);
		(npath, nil) = str->splitstrr(f.path, "/");
		if(npath != nil) {
			if(!suffix("/", npath))
				raise sprint("npath does not have / at end?, npath %q", npath);
			npath = npath[:len npath-1];
		}
	} else {
		if(npath != nil)
			npath += "/";
		npath += name;
	}

	# xxx could be done more efficiently
	for(i := 0; i < len r.tree; i++)
		if(r.tree[i].path == npath)
			return r.stat(i);
	say(sprint("revtree.walk, no hit for %q in %q", npath, f.path));
	return (nil, styxservers->Enotfound);
}

Revtree.read(r: self ref Revtree, gen: int): (array of byte, string)
{
	f := r.tree[gen];
	say(sprint("revtree.read, f %s", f.text()));
	if(f.data == nil) {
		say(sprint("revtree.read, no data yet, reading..."));
		(data, err) := repo.readfile(f.path, f.nodeid);
		if(err != nil)
			return (nil, err);
		f.data = data;
	}
	return (f.data, nil);
}

Revtree.stat(r: self ref Revtree, gen: int): (ref Sys->Dir, string)
{
	f := r.tree[gen];
	say(sprint("revtree.stat, rev %d, file %s", r.rev, f.text()));

	q := Qrepofile;
	d := ref sys->zerodir;

	if(gen == 0)
		d.name = sprint("%d", r.rev);
	else
		d.name = str->splitstrr(f.path, "/").t1;

	d.uid = d.gid = "hg";
	d.qid.path = big Qrepofile|big gen<<8|big r.rev<<32;
	if(f.isdir())
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.length = big 0; # xxx
	d.mtime = d.atime = 0; # xxx
	d.mode = f.mode();
	say("revtree.stat, done");
	return (d, nil);
}


Tgz: adt {
	rev:	int;
	tgzoff:	big;
	pid:	int;  # of filter
	rq:	chan of ref Rq;
	manifest:	ref Manifest;

	data:	array of byte;  # of file-in-progress
	mf:	list of ref Manifestfile;  # remaining files

	tgzdata:	array of byte;  # output from filter

	new:	fn(rev: int): (ref Tgz, string);
	read:	fn(t: self ref Tgz, n: int, off: big): (array of byte, string);
	close:	fn(t: self ref Tgz);
};

Tgz.new(rev: int): (ref Tgz, string)
{
	(nil, manifest, err) := repo.manifest(rev);
	if(err != nil)
		return (nil, err);

	rq := deflate->start("h");
	msg := <-rq;
	pid: int;
	pick m := msg {
	Start =>	pid = m.pid;
	* =>		fail(sprint("bogus first message from deflate"));
	}

	t := ref Tgz(rev, big 0, pid, rq, manifest, array[0] of byte, manifest.files, array[0] of byte);
	return (t, nil);
}

Tgz.read(t: self ref Tgz, n: int, off: big): (array of byte, string)
{
	say(sprint("tgz.read, n %d off %bd", n, off));

	if(off != t.tgzoff)
		return (nil, "random reads on .tgz's not supported");

	if(t.mf == nil && len t.data == 0)
		return (array[0] of byte, nil);

	if(len t.tgzdata == 0) {
		# handle filter msgs until we find either result, finished, or error
	next:
		for(;;) {
			pick m := (msg := <-t.rq) {
			Fill =>
				if(len t.data == 0) {
					if(t.mf == nil) {
						m.reply <-= 0;
						continue next;
					}

					f := hd t.mf;
					t.mf = tl t.mf;

					say(sprint("tgz.read, starting on next file, %q", f.path));
					(data, err) := repo.readfile(f.path, f.nodeid);
					if(err != nil)
						return (nil, err);

					last := 0;
					if(t.mf == nil)
						last = 2*512;

					hdr := tarhdr(f.path, big len data, 0);
					pad := len data % 512;
					if(pad != 0)
						pad = 512-pad;
					t.data = array[len hdr+len data+pad+last] of byte;
					t.data[len t.data-(pad+last):] = array[pad+last] of {* => byte 0};
					t.data[:] = hdr;
					t.data[len hdr:] = data;
				}

				give := len m.buf;
				if(len t.data < give)
					give = len t.data;
				m.buf[:] = t.data[:give];
				t.data = t.data[give:];
				m.reply <-= give;
				
			Result =>
				t.tgzdata = array[len m.buf] of byte;
				t.tgzdata[:] = m.buf;
				m.reply <-= 1;
				break next;
			Finished =>
				if(len m.buf != 0)
					raise "deflate had leftover data...";
				break next;
			Info =>
				say("inflate info: "+m.msg);
			Error =>
				return (nil, m.e);
			}
		}
	}

	give := n;
	if(len t.tgzdata < give)
		give = len t.tgzdata;
	rem := array[len t.tgzdata-give] of byte;
	rem[:] = t.tgzdata[give:];
	r := array[give] of byte;
	r[:] = t.tgzdata[:give];
	t.tgzdata = rem;
	t.tgzoff += big give;
	return (r, nil);
}

Tgz.close(t: self ref Tgz)
{
	if(t.pid >= 0)
		kill(t.pid);
	t.pid = -1;
}


TARPATH:	con 0;
TARMODE:	con 100;
TARUID:		con 108;
TARGID:		con 116;
TARSIZE:	con 124;
TARMTIME:	con 136;
TARCHECKSUM:	con 148;
TARLINK:	con 156;
tarhdr(path: string, size: big, mtime: int): array of byte
{
	d := array[512] of {* => byte 0};
	d[TARPATH:] = array of byte path;
	d[TARMODE:] = array of byte string sprint("%8o", 8r644);
	d[TARUID:] = array of byte string sprint("%8o", 0);
	d[TARGID:] = array of byte string sprint("%8o", 0);
	d[TARSIZE:] = array of byte sprint("%12bo", size);
	d[TARMTIME:] = array of byte sprint("%12o", mtime);
	d[TARLINK] = byte '0'; # '0' is normal file;  '5' is directory

	d[TARCHECKSUM:] = array[8] of {* => byte ' '};
	sum := 0;
	for(i := 0; i < len d; i++)
		sum += int d[i];
	d[TARCHECKSUM:] = array of byte sprint("%6o", sum);
	d[TARCHECKSUM+6:] = array[] of {byte 0, byte ' '};
	return d;
}


suffix(suf, s: string): int
{
	return len suf <= len s && suf == s[len s-len suf:];
}

has(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return 1;
	return 0;
}

l2a[T](l: list of T): array of T
{
	a := array[len l] of T;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

kill(pid: int)
{
	fd := sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

fail(s: string)
{
	warn(s);
	raise "fail:"+s;
}