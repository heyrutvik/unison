## TODO tracking refactoring of existing functionality

* [ ] Implement `Branch.sync` operation that synchronizes a monadic `Branch` to disk
* [ ] Implement something like `Branch.fromDirectory : FilePath -> IO (Branch IO)` for getting a lazy proxy for a `Branch`
  - Also `Branch.fromExternal : (Path -> m ByteString) -> Hash -> m (Branch m)`
  - Could we create a `Branch` from a GitHub reference? Seems like yeah, it's just going to do some HTTP fetching.
* [ ] Implement `Codebase2` that is a tweaked version of `Codebase`
* [ ] Implement `Edits2`
* [ ] Implement `Actions2`
* [ ] Implement `OutputMessages2`
* [ ] Implement `InputPatterns2`

* [ ] Split Edits out of `Branch0`
* [ ] Delete `oldNamespace`, and instead add deprecated names
* [ ] Parsing takes a `Names`, a map from `Name`(fully-qualified name) to `Referent`/`Reference`.  We should switch these from `Map` to `Name -> Optional xxx`, or even `Name -> m (Optional xxx)`
* [ ] `Context.synthesizeClosed` takes a `TypeLookup`, which includes a map from `Reference` to `Type`, `DataDecl`, `EffectDecl`.  Shall we plan to include the full codebase here, or load them on demand?  Maybe it doesn't matter yet.
  * `parseAndSynthesizeFile` takes  a `Set Reference -> m (TypeLookup v Ann)`, maybe that's a good model.
* [ ] `add` and `update` will need a way to update the `Branch'` at the current level, and all the way back to the root.  Some kind of zipper?
* [ ] `find` takes an optional path
* [ ] `fork` takes a `RepoPath` (or we could have a dedicated command like `clone`)
* [ ] `merge` takes at least a path, if not a `RepoPath`
* [ ] `publish` or `push`that takes a local path and a remote path? 

# Branchless codebase format

## Namespaces

```haskell
data Branch' m = Branch' (Causal m Namespace)

data Causal m e
  = One { currentHash :: Hash, head :: e }
  | Cons { currentHash :: Hash, head :: e, tail :: m (Causal e) }
  -- The merge operation `<>` flattens and normalizes for order
  | Merge { currentHash :: Hash, head :: e, tails :: Map Hash (m (Causal e)) }

-- just one level of name, like Foo or Bar, but not Foo.Bar
newtype NameSegment = NameSegment { toText :: Text } -- no dots, no slashes
newtype Path = Path { toList :: [NameSegment] }

data Namespace m = Namespace
	{ terms :: Relation NameSegment Referent
  , types :: Relation NameSegment Reference
  , children :: Relation NameSegment (Branch' m) 
  }
```

**<u>Repo format:</u>**

```
# types
.unison/types/<hash>/compiled.ub
.unison/types/<hash>/dependents/<hash>
.unison/types/_builtin/<base58>/dependents/<hash>

# terms
.unison/terms/<hash>/compiled.ub
.unison/terms/<hash>/type.ub
.unison/terms/<hash>/dependents/<hash>
.unison/terms/_builtin/<base58>/dependents/<hash>

# branches (hashes of Causal m Namespace)
.unison/branches/<hash>.ubf
.unison/branches/head/<hash> -- if several, merge to produce new head.
```

### Backup Names?

For pretty-printing, we want a name for every hash.  Even for hashes we deleted the names for. 😐  

* When we delete a name `x` from path `/p` (i.e. `/p/x`), we add the name `/_deleted/p/x`. <!-- pchiusano: I like this option, it's simple -->

* Or, do we just disallow removing the last name of things with dependencies?

* When deleting a name, notify the user of the remaining names.

## Edits

```haskell
newtype EditMap = EditMap { toMap :: Map GUID (Causal Edits) }

data Edits = Edits
	{ terms :: Relation Reference TermEdit 
	, types :: Relation Reference TypeEdit
	}

type FriendlyEditNames = Relation Text GUID
```

**<u>Repo format:</u>**

```
.unison/edits/<guid>/<hash>
.unison/edits/<guid>/name/<base58> -- (base58encode (utf8encode "name of the edit"))
.unison/edits/<guid>/head/<hash> -- if several, merge to produce new head.
```

### TODO: How to share these edits?

* It could be the same as sharing Unison names (e.g. if the edits were Unison terms)
* It could be the same as sharing Unison definitions:
  Make up a URI that references a repo and an edit GUID.
  e.g. `https://github.com/<user>/<repo>/<...>/<guid>[/hash]`

---

## Collecting external dependencies

If a subtree references external dependencies, they should be given local names when exporting.

Given:

```
/A/B/c#xxx
/D/E/f#yyy (depends on #xxx, #zzz)
/D/G/h#zzz
```

If `/D/E` is published, what names should be assigned to `#xxx`, `#zzz`?

### Idea 1: Names relative to nearest parent

Collect external dependencies under `Dependencies`, using names relative to the nearest parent in common with the publication point?

i.e.:

```
f#yyy
Dependencies/A/B/C#xxx
Dependencies/G/h#zzz
```

<!-- pchiusano: 
I like this option the best. Reasons:

- Option 2 seems ill defined and probably complicated, so let's nix that.
- Option 3 is simple, but is more work for the user, and also the easiest way for the user to address is to copy the whole tree of whatever dependent library they are using, even if they are just using a handful of functions. An automated procedure can produce a minimal set of named dependencies.
- Having a somewhat opinionated convention like this makes the code easier to read - you can easily view the minimal third-party dependencies used by a library.
- Option 1 doesn't preclude you from picking some other convention for where you put those dependencies, if you really want.

--> 

### Idea 2: Somehow derive from qualified imports used?

If 

### Idea 3: Surface the condition* to the user 

*the condition = the publication node contains definitions that reference definitions not under the publication node.

Ask them to create aliases below the publication point?

### Idea 4: Add external names to `./_auxNames/` 

The nearest aux-name would only be used to render code only if there were no primary names known.

<!-- pchiusano: hmm, how does this differ from Idea 3? --> 

### Idea 5: Something with symlinks

## Syncing with remote codetrees

```haskell
-- names tbd
data BranchPath = BranchPath RepoRef Path
data RepoRef = Local | GithubRef { username :: Text, repo :: Text, treeish :: Text }

```
```
/libs/community/DL
```
becomes
```haskell
BranchPath Local (Path ["libs","community","DL"])
```



```
gh:<user>/<repo>[/<path>][?ref=<treeish>] -- defaults to repo's `default_branch`

e.g. gh:aryairani/unison/libs?ref=topic/370
```
becomes
```haskell
BranchPath (GithubRef "aryairani" "unison" "topic/370") (Path ["libs"])
```
or
```
gh:user/repo[:treeish][/path]

e.g. github:aryairani/unison:topic/370/libs
```

becomes

```haskell
BranchPath (GithubRef "'aryairani" "unison" "topic/370") (Path ["libs"])
```


## Github Notes

Github uses a few different URL schemes.  They call the ones you can pluck off their website "html_url"s.  They let you refer to files and directories, and can be parameterized by git _treeish_ (branch, tag, commit).  

We can interpret these to refer to the root of a namespace. https://github.com/unisonweb/unison can be interpreted as:

```haskell
GithubRef "unisonweb" "unison" <$> getDefaultBranch "unisonweb" "unison"
```

The Github website will let you navigate to a git branch, e.g https://github.com/unisonweb/unison/tree/topic/370/ can be interpreted as:

```haskell
GithubRef "unisonweb" "unison" <$> matchBranch "unisonweb" "unison" "topic/370/"
```

Branch names can contain slashes, such as `topic/370`, complicating parsing if there's meant to be path info following the branch name.  

1. Fortunately, if you have a git branch `a/b` then it's not possible to create branches `a` or `a/b/c`.  So you can load the [list of branches](https://api.github.com/repos/unisonweb/unison/branches) from JSON, and then test them against that treeish-prefixed path without ambiguity.
2. Github's website doesn't know how to navigate into `Causal` structures, so it's never going to give us URLs with paths into a Unison namespace.  So maybe this is a moot point.

So, I would still go ahead with the made-up `gh:username/repo[:treeish][/path]` URI scheme; we can try to support the other URLs mentioned above, and let them refer to the root of the published namespace.  

Our Javascript viewer can be made to create URLs with query params or fragments in them that can indicate the Unison path, and those can be the ones we share in tweets, etc:

http(s)://<username>.github.io/<projectname>?branch=<hash>&path=<path> with the default branch being the head, and the default path being /.

