package;


import haxe.remoting.HttpConnection;
import haxe.remoting.Proxy;
import haxe.zip.*;
import haxe.Http;
import haxe.Json;
import haxe.Serializer;
import haxe.Timer;
import haxe.Unserializer;
import haxelib.Data;
import haxelib.SemVer;
import hxp.*;
import sys.FileSystem;
import sys.io.File;


class Script extends hxp.Script {
	
	
	private var haxelibProxy:HaxelibProxy;
	
	
	public function new () {
		
		super ();
		
		switch (command) {
			
			case "default":
				
				Log.info ("Commands:");
				
				var commands = [ "projects", "versions", "download", "extract", "patch", "publish" ];
				
				for (command in commands) {
					
					Log.info (" - " + command);
					
				}
			
			case "projects":
				
				var projects = getProjectList (false);
				Log.info ("Projects:");
				
				for (project in projects) {
					
					Log.info (" - " + project);
					
				}
			
			case "versions":
				
				Log.info ("Versions:");
				var projects = [];
				
				if (commandArgs.length > 0) {
					
					projects.push (commandArgs[0]);
					
				} else {
					
					projects = getProjectList (true);
					
				}
				
				for (project in projects) {
					
					Log.info ("(Project: " + project + ")");
					var versions = getProjectVersions (project, false);
					Log.info (Std.string (versions));
					
				}
			
			case "download":
				
				Log.info ("Download:");
				var projects = [];
				
				if (commandArgs.length > 0) {
					
					projects.push (commandArgs[0]);
					
				} else {
					
					projects = getProjectList (true);
					
				}
				
				var SERVER = {
					protocol : "https",
					host : "lib.haxe.org",
					port : 443,
					dir : "",
					url : "index.n",
					apiVersion : "3.0",
				};
				
				var siteURL = SERVER.protocol + "://" + SERVER.host + ":" + SERVER.port + "/" + SERVER.dir;
				
				for (project in projects) {
					
					var versions = getProjectVersions (project, true);
					var downloadPath = Path.combine ("out/download", project);
					System.mkdir (downloadPath);
					
					for (version in versions) {
						
						var filename = Data.fileName(project,version);
						var url = Path.join ([ siteURL, Data.REPOSITORY, filename ]);
						Log.info (url);
						download (url, Path.combine (downloadPath, version + ".zip"));
						
					}
					
				}
			
			case "patch":
				
				Log.info ("Patch:");
				var projects = [];
				
				if (commandArgs.length > 0) {
					
					projects.push (commandArgs[0]);
					
				} else {
					
					projects = getProjectList (true);
					
				}
				
				for (project in projects) {
					
					var versions = getProjectVersions (project, true);
					var downloadPath = Path.combine ("out/download", project);
					
					for (version in versions) {
						
						var filePath = Path.combine (downloadPath, version + ".zip");
						if (FileSystem.exists (filePath)) {
							
							var outputDirectory = "out/staging/" + project + "/" + Data.safe (version);
							unzip (filePath, outputDirectory);
							patch (outputDirectory);
							
						}
						
					}
					
				}
			
			default:
			
		}
		
	}
	
	
	private function download (fileURL:String, outPath:String, maxRedirects = 20):Void {
		
		inline function createHttpRequest(url:String):Http {
			var req = new Http(url);
			// req.addHeader("User-Agent", 'haxelib $VERSION_LONG');
			if (haxe.remoting.HttpConnection.TIMEOUT == 0)
				req.cnxTimeout = 0;
			return req;
		}
		
		var out = try File.append(outPath,true) catch (e:Dynamic) throw 'Failed to write to $outPath: $e';
		out.seek(0, SeekEnd);

		var h = createHttpRequest (fileURL);

		var currentSize = out.tell ();
		if (currentSize > 0)
			h.addHeader("range", "bytes="+currentSize + "-");

		var progress = if (true /*settings != null && settings.quiet == false*/)
			new ProgressOut(out, currentSize);
		else
			out;

		var httpStatus = -1;
		var redirectedLocation = null;
		h.onStatus = function(status) {
			httpStatus = status;
			switch (httpStatus) {
				case 301, 302, 307, 308:
					switch (h.responseHeaders.get("Location")) {
						case null:
							throw 'Request to $fileURL responded with $httpStatus, ${h.responseHeaders}';
						case location:
							redirectedLocation = location;
					}
				default:
					// TODO?
			}
		};
		h.onError = function(e) {
			progress.close();

			switch(httpStatus) {
				case 416:
					// 416 Requested Range Not Satisfiable, which means that we probably have a fully downloaded file already
					// if we reached onError, because of 416 status code, it's probably okay and we should try unzipping the file
				default:
					FileSystem.deleteFile(outPath);
					throw e;
			}
		};
		h.customRequest(false, progress);

		if (redirectedLocation != null) {
			FileSystem.deleteFile(outPath);

			if (maxRedirects > 0) {
				download(redirectedLocation, outPath, maxRedirects - 1);
			} else {
				throw "Too many redirects.";
			}
		}
	}
	
	
	private function getProjectList (allowCache:Bool):Array<String> {
		
		var cacheFile = Path.combine ("out/data", "projects.dat");
		var list = [];
		
		if (allowCache && FileSystem.exists (cacheFile)) {
			
			list = Unserializer.run (File.getContent (cacheFile));
			
		} else {
			
			var all = haxe.Http.requestUrl ("https://lib.haxe.org/all/");
			
			var searchString = "href=\"/p/";
			var index = all.indexOf (searchString);
			
			while (index > -1) {
				
				var start = index + searchString.length;
				var end = all.indexOf ("\"", index + searchString.length) -1;
				list.push (all.substring (start, end));
				index = all.indexOf (searchString, end);
				
			}
			
			System.mkdir ("out/data");
			var data = Serializer.run (list);
			File.saveContent (cacheFile, data);
			
		}
		
		return list;
		
	}
	
	
	private function getProjectVersions (project:String, allowCache:Bool = true):Array<SemVer> {
		
		var cacheFile = Path.combine ("out/data", "versions-" + project + ".dat");
		var versions = [];
		
		if (allowCache && FileSystem.exists (cacheFile)) {
			
			versions = Unserializer.run (File.getContent (cacheFile));
			
		} else {
			
			if (haxelibProxy == null) {
				
				var SERVER = {
					protocol : "https",
					host : "lib.haxe.org",
					port : 443,
					dir : "",
					url : "index.n",
					apiVersion : "3.0",
				};
				
				var siteURL = SERVER.protocol + "://" + SERVER.host + ":" + SERVER.port + "/" + SERVER.dir;
				var remotingURL =  siteURL + "api/" + SERVER.apiVersion + "/" + SERVER.url;
				haxelibProxy = new HaxelibProxy (HttpConnection.urlConnect (remotingURL).resolve ("api"));
				
			}
			
			var info = haxelibProxy.infos (project);
			
			for (version in info.versions) {
				versions.push (version.name);
			}
			
			System.mkdir ("out/data");
			var data = Serializer.run (versions);
			File.saveContent (cacheFile, data);
			
		}
		
		return versions;
		
	}
	
	
	private static function findProjectFolder (basePath:String, path:String):String {
		
		var directory = Path.combine (basePath, path);
		
		for (file in FileSystem.readDirectory (directory)) {
			
			if (file == "haxelib.json") return directory;
			
			var fullPath = Path.combine (directory, file);
			var childPath = Path.combine (path, file);
			
			if (FileSystem.isDirectory (fullPath)) {
				
				var path = findProjectFolder (basePath, childPath);
				if (path != null) return path;
				
			}
			
		}
		
		return null;
		
	}
	
	
	private function patch (stagingDirectory:String):Void {
		
		var root = findProjectFolder (stagingDirectory, "");
		
		if (root != null) {
			
			var packageJSON = Path.combine (root, "package.json");
			
			if (!FileSystem.exists (packageJSON)) {
				
				Log.info ("Patching " + stagingDirectory);
				var info = Data.readData (File.getContent (Path.combine (root, "haxelib.json")), false);
				
				var json:Dynamic = {
					
					name: "@haxelib/" + info.name,
					license: Std.string (info.license),
					version: Std.string (info.version),
					contributors: info.contributors
					
				}
				
				if (Reflect.hasField (info, "url")) {
					json.homepage = info.url;
				}
				
				if (Reflect.hasField (info, "description")) {
					json.description = info.description;
				}
				
				if (Reflect.hasField (info, "tags")) {
					json.keywords = info.tags;
				}
				
				if (Reflect.field (info, "dependencies")) {
					var dependencies:Dynamic = {};
					for (dependency in info.dependencies) {
						if (dependency.type == Haxelib) {
							Reflect.setField (dependencies, dependency.name, Std.string (dependency.version));
						} else if (dependency.url != null) {
							Reflect.setField (dependencies, dependency.name, dependency.url);
						}
					}
					json.devDendencies = dependencies;
				}
				
				File.saveContent (packageJSON, Json.stringify (json, null, "  "));
				
			}
			
		}
		
	}
	
	
	private function unzip (filepath:String, output:String):Void {
		
		// Not sure haxe.zip.Reader works properly in eval target
		
		System.mkdir (output);
		Log.info ("Extracting " + filepath);
		if (FileSystem.exists (output)) System.removeDirectory (output);
		System.runProcess ("", "unzip", [ filepath, "-d", output ]);
		
		// // read zip content
		// trace (filepath);
		// filepath = Path.tryFullPath (filepath);
		// trace (filepath);
		// var f = File.read(filepath,true);
		// var zip = try {
		// 	Reader.readZip(f);
		// } catch (e:Dynamic) {
		// 	f.close();
		// 	// file is corrupted, remove it
		// 	// if (!nodelete)
		// 		// FileSystem.deleteFile(filepath);
		// 	throw e;
		// }
		// f.close();
		// var infos = Data.readInfos(zip,false);
		// Log.info('Staging ${infos.name}...');
		// // create directories
		// var target = output;
		// target += "/";

		// // locate haxelib.json base path
		// var basepath = Data.locateBasePath(zip);

		// // unzip content
		// var entries = [for (entry in zip) if (StringTools.startsWith (entry.fileName, basepath)) entry];
		// var total = entries.length;
		// for (i in 0...total) {
		// 	var zipfile = entries[i];
		// 	var n = zipfile.fileName;
		// 	// remove basepath
		// 	n = n.substr(basepath.length,n.length-basepath.length);
		// 	if( n.charAt(0) == "/" || n.charAt(0) == "\\" || n.split("..").length > 1 )
		// 		throw "Invalid filename : "+n;

		// 	// if (settings.debug) {
		// 	// 	var percent = Std.int((i / total) * 100);
		// 	// 	Sys.print('${i + 1}/$total ($percent%)\r');
		// 	// }

		// 	var dirs = ~/[\/\\]/g.split(n);
		// 	var path = "";
		// 	var file = dirs.pop();
		// 	for( d in dirs ) {
		// 		path += d;
		// 		// safeDir(target+path);
		// 		path += "/";
		// 	}
		// 	if( file == "" ) {
		// 		// if( path != "" && settings.debug ) print("  Created "+path);
		// 		continue; // was just a directory
		// 	}
		// 	path += file;
		// 	// if (settings.debug)
		// 	// 	print("  Install "+path);
		// 	var data = Reader.unzip(zipfile);
		// 	File.saveBytes(target+path,data);
		// }

		// // set current version
		// // if( setcurrent || !FileSystem.exists(pdir+".current") ) {
		// // 	File.saveContent(pdir + ".current", infos.version);
		// // 	print("  Current version is now "+infos.version);
		// // }

		// // end
		// // if( !nodelete )
		// // 	FileSystem.deleteFile(filepath);
		// // print("Done");

		// // process dependencies
		// // doInstallDependencies(rep, infos.dependencies);

		// // return infos;
		
	}
	
	
}


class HaxelibProxy extends Proxy<haxelib.SiteApi> {}


class ProgressOut extends haxe.io.Output {

	var o : haxe.io.Output;
	var cur : Int;
	var startSize : Int;
	var max : Null<Int>;
	var start : Float;

	public function new(o, currentSize) {
		this.o = o;
		startSize = currentSize;
		cur = currentSize;
		start = Timer.stamp();
	}

	function report(n) {
		cur += n;
		if( max == null )
			Sys.print(cur+" bytes\r");
		else
			Sys.print(cur+"/"+max+" ("+Std.int((cur*100.0)/max)+"%)\r");
	}

	public override function writeByte(c) {
		o.writeByte(c);
		report(1);
	}

	public override function writeBytes(s,p,l) {
		var r = o.writeBytes(s,p,l);
		report(r);
		return r;
	}

	public override function close() {
		super.close();
		o.close();
		var time = Timer.stamp() - start;
		var downloadedBytes = cur - startSize;
		var speed = (downloadedBytes / time) / 1024;
		time = Std.int(time * 10) / 10;
		speed = Std.int(speed * 10) / 10;
		Sys.print("Download complete : "+downloadedBytes+" bytes in "+time+"s ("+speed+"KB/s)\n");
	}

	public override function prepare(m) {
		max = m + startSize;
	}

}