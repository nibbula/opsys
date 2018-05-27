;;
;; unix/unix.lisp - Unix interface to files and filesystems
;;

(in-package :opsys-unix)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Directories

(defun hidden-file-name-p (name)
  "Return true if the file NAME is normally hidden."
  (and name (> (length name) 0) (equal (char name 0) #\.)))

(defun superfluous-file-name-p (name)
  "Return true if the file NAME is considered redundant. On POSIX file
systems, this means \".\" and \"..\"."
  (and name (> (length name) 0)
       (or (and (= (length name) 1)
		(equal (char name 0) #\.))
	   (and (= (length name) 2)
		(equal (char name 0) #\.)
		(equal (char name 1) #\.)))))

;; We need to use the posix version if there's no better way to do it
;; on the implementation.
;#+openmcl (config-feature :os-t-use-chdir)
;#+os-t-use-chdir (defcfun chdir :int (path :string))
#+(or openmcl sbcl abcl) (defcfun chdir :int (path :string))

;; The real question is should this munge *default-pathname-defaults* ?
;; On implementations where "load" works from *default-pathname-defaults*
;; and not from the OS current, I say yes.

;; @@@@ Need to work out the generic way

(defun change-directory (&optional path)
  "Change the current directory to DIR. Defaults to (user-homedir-pathname) ~
if not given."
  (when (not path)
    (setf path (enough-namestring (user-homedir-pathname))))
  (when (pathnamep path)
    (setf path (safe-namestring path)))
  #+openmcl (syscall (chdir path))
  #+sbcl (progn
	   (syscall (chdir path))
	   (let ((tn (ignore-errors (truename path))))
	     (when tn
	       (setf *default-pathname-defaults* tn))))
  #+clisp (ext:cd path)
  #+excl (setf *default-pathname-defaults* (pathname (excl:chdir path)))
  #+cmu (setf (ext:default-directory) path)
  #+ecl
  ;; try to turn it into a directory
  ;;; @@@ this fails for .. or .
  ;;(ext:chdir (if (not (pathname-directory path))
  ;;  (make-pathname :directory `(:relative ,path))
  ;;  (make-pathname :directory path)))
  ;;; try something simpler but os dependent
  (ext:chdir (if (and (stringp path) (length path))
		 (concatenate 'string path "/")
		 path))
  #+lispworks (hcl:change-directory path)
  #+abcl
  (progn
    (syscall (chdir path))
    (setf *default-pathname-defaults* (truename path)))
  #-(or clisp excl openmcl sbcl cmu ecl lispworks abcl)
  (missing-implementation 'change-directory))

(defcfun ("getcwd" real-getcwd) :pointer (buf :pointer) (size size-t))
(defcfun pathconf :long (path :string) (name :int))
(defconstant +PC-PATH-MAX+
	 #+(or darwin sunos freebsd) 5
	 #+linux 4)
#-(or darwin sunos linux freebsd) (missing-implementation 'PC-PATH-MAX)
;; Using the root "/" is kind of bogus, because it can depend on the
;; filesystem type, but since we're using it to get the working directory.
;; This is where grovelling the MAXPATHLEN might be good.
(defparameter *path-max* nil
  "Maximum number of bytes in a path.")
(defun get-path-max ()
  (or *path-max*
      (setf *path-max* (pathconf "/" +PC-PATH-MAX+))))

(defun libc-getcwd ()
  "Return the full path of the current working directory as a string, using the
C library function getcwd."
  (let ((cwd (with-foreign-pointer-as-string (s (get-path-max))
	       (foreign-string-to-lisp (real-getcwd s (get-path-max))))))
    (if (not cwd)		; hopefully it's still valid
	(error 'posix-error :error-code *errno* :format-control "getcwd")
	cwd)))

(defun current-directory ()
  "Return the full path of the current working directory as a string."
  ;; I would like to use EXT:CD, but it puts an extra slash at the end.
  #+(or clisp sbcl cmu) (libc-getcwd)
  #+excl (excl:current-directory)
  #+(or openmcl ccl) (ccl::current-directory-name)
  #+ecl (libc-getcwd) ;; (ext:getcwd)
  ;; #+cmu (ext:default-directory)
  #+lispworks (hcl:get-working-directory)
  #+abcl (namestring (truename *default-pathname-defaults*))
  #-(or clisp excl openmcl ccl sbcl cmu ecl lispworks abcl)
  (missing-implementation 'current-directory))

(defcfun mkdir :int (path :string) (mode mode-t))

(defun make-directory (path &key (mode #o755))
  "Make a directory."
  ;; The #x1ff is because mkdir can fail if any other than the low nine bits
  ;; of the mode are set.
  (syscall (mkdir (safe-namestring path) (logand #x1ff (or mode #o777)))))

(defcfun rmdir :int (path :string))

(defun delete-directory (path)
  "Delete a directory."
  (syscall (rmdir (safe-namestring path))))

;; It's hard to fathom how insanely shitty the Unix/POSIX interface to
;; directories is. On the other hand, I might have trouble coming up with
;; a too much better interface in plain old ‘C’. Just rebuild the kernel.
;; Works fine in a two person dev team.

;; We just choose something big here and hope it works.
(defconstant MAXNAMLEN 1024 "Maximum length of a file name.")

(defconstant DT_UNKNOWN       0 "Unknown ")
(defconstant DT_FIFO          1 "FIFO file aka named pipe")
(defconstant DT_CHR           2 "Character special aka raw device")
(defconstant DT_DIR           4 "Directory file")
(defconstant DT_BLK           6 "Block special aka block device")
(defconstant DT_REG           8 "Regular file")
(defconstant DT_LNK          10 "Symbolic link")
(defconstant DT_SOCK         12 "Socket aka unix domain socket")
(defconstant DT_WHT          14 "A whiteout file! for overlay filesystems")

;; Darwin 64 bit vs 32 bit dirent:
;;
;; There are two things which are theoretically independent: whether the
;; **kernel** is 64 bit or not, and whether the execution environment is 64
;; bit or not. If the kernel is 64 bit (*64-bit-inode*), we have to use the 64
;; inode structure. If the executable environment is 64 bit (aka
;; 64-bit-target) we have to use the 64 bit function calls. But It seems like
;; now the function calls in the 32 bit executable environment can handle the
;; 64 bit dirent structure.
;; 
;; So, also, there are special readdir, etc. routines, ending in various
;; combinations of "$INODE64" and "$UNIX2003" which are partially dependent on
;; the word size of executable environment. Will this work on previous OS
;; versions? Will it work on a 32 bit kernel? I have no idea. Thanks to
;; "clever" hackery with "asm" and CPP, you can change the ancient function
;; calls right under everybody and "NO ONE WILL KNOW", right? Wrong.
;;
;; It's a complete mess, and I got this wrong for quite a long time. I think I
;; should probably just give in and use a groveler, or at least: check the
;; output from the C compiler!!

;; #+(and darwin (not os-t-64-bit-inode))
;; (defcstruct foreign-dirent
;;      "Entry in a filesystem directory. struct dirent"
;;   (d_ino	ino-t)
;;   (d_reclen	:uint16)
;;   (d_type	:uint8)
;;   (d_namlen	:uint8)
;;   (d_name	:char :count 256))

;; #+(and darwin os-t-64-bit-inode)
#+darwin ;; This seems to be it for both 32 & 64
(defcstruct foreign-dirent
  "Entry in a filesystem directory. struct dirent"
  (d_ino	ino-t)
  (d_seekoff	:uint64)
  (d_reclen	:uint16)
  (d_namlen	:uint16)
  (d_type	:uint8)
  (d_name	:char :count 1024))

#|
(defun dumply (type)
  (format t "~a~%" (foreign-type-size type))
  (format t "~a~%" (foreign-type-alignment type))
  (with-foreign-object (instance type)
    (let ((ll 
	   (loop :for slot :in (foreign-slot-names type)
	      :collect (list  
			slot (foreign-slot-offset type slot)
			(- (pointer-address
			    (foreign-slot-pointer instance type slot))
			   (pointer-address instance))))))
      (setf ll (sort ll #'< :key #'second))
      (loop :for l :in ll :do
	 (format t "~10a ~a ~a~%" (first l) (second l) (third l))))))
|#

#+sunos
(defcstruct foreign-dirent
  "Entry in a filesystem directory. struct dirent"
  (d_ino	ino-t)
  (d_off	off-t)
  (d_reclen	:unsigned-short)
  (d_name	:char :count 1024))

#+linux
(defcstruct foreign-dirent
  "Entry in a filesystem directory. struct dirent"
  (d_ino	ino-t)
  (d_off	off-t)
  (d_reclen	:unsigned-short)
  (d_type	:uint8)
  (d_name	:char :count 1024))

#+freebsd
(defcstruct foreign-dirent
  ;; I know they really want to call it "fileno", but please let's just call
  ;; it "ino" for compatibility.
  ;; (d_fileno	:uint32)
  (d_ino	:uint32)
  (d_reclen	:uint16)
  (d_type	:uint8)
  (d_namlen	:uint8)
  (d_name	:char :count #.(+ 255 1)))

#+(or linux darwin freebsd)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (config-feature :os-t-has-d-type))

;; If one of these is not defined, we just use strlen(d_name).
#+(or darwin freebsd) (config-feature :os-t-has-namlen)
#+linux (config-feature :os-t-has-reclen)

#|
(defun fooberry () "64 bit dirent, 32 bit functions"
  (let* ((dd (cffi:foreign-funcall
	      #+64-bit-target "opendir$INODE64"
	      #+32-bit-target "opendir"
	      :string "." :pointer))
	 dp nn)
    (loop :while
       (not (cffi:null-pointer-p
	     (setf dp (cffi:foreign-funcall
		       #+64-bit-target "readdir$INODE64"
		       #+32-bit-target "readdir"
		       :pointer dd :pointer))))
       :do
       (setf nn (cffi:foreign-slot-value
		 dp '(:struct nos::foreign-dirent) 'nos::d_name))
       (format t "~a~%"
	       (cffi:foreign-slot-value
		dp '(:struct foreign-dirent) 'nos::d_namlen)
	       ;; (cffi:foreign-string-to-lisp
	       ;; 	(setf nn (cffi:foreign-slot-value
	       ;; 		  dp '(:struct
	       ;; 		       #+64-bit-target nos::foreign-dirent-64
	       ;; 		       #+32-bit-target nos::foreign-dirent-64
	       ;; 		       ) 'nos::d_name))))
	       )
       (loop :with i = 0 :and c = nil
	  :do (setf c (cffi:mem-aref nn :char i))
	  (cond ((= c 0) (terpri))
		((> c 0) (princ (code-char c)))
		(t ))
	  (incf i)
	  :while (/= 0 c)))))
|#

;; opendir
#+(and darwin 64-bit-target)
(defcfun ("opendir$INODE64" opendir) :pointer (dirname :string))
#+(and darwin (not 64-bit-target))
(defcfun ("opendir$INODE64$UNIX2003" opendir) :pointer (dirname :string))
#-darwin (defcfun opendir :pointer (dirname :string))

;; closedir
#+(and darwin 64-bit-target)
(defcfun ("closedir" closedir) :int (dirp :pointer))
#+(and darwin (not 64-bit-target))
(defcfun ("closedir$UNIX2003" closedir) :int (dirp :pointer))
#-darwin
(defcfun closedir :int (dirp :pointer))

;; readdir_r
#+(and darwin 64-bit-target)
(defcfun ("readdir_r$INODE64" readdir_r)
 	    :int (dirp :pointer) (entry :pointer) (result :pointer))
#+(and darwin (not 64-bit-target))
(defcfun ("readdir_r$INODE64" readdir_r)
 	     :int (dirp :pointer) (entry :pointer) (result :pointer))
#+sunos (defcfun ("__posix_readdir_r" readdir_r)
	    :int (dirp :pointer) (entry :pointer) (result :pointer))
#-(or darwin sunos)
(defcfun readdir_r :int (dirp :pointer) (entry :pointer) (result :pointer))

;; readdir
#+(and darwin 64-bit-target)
(defcfun ("readdir$INODE64" readdir) :pointer (dirp :pointer))
#+(and darwin (not 64-bit-target))
(defcfun ("readdir$INODE64" readdir) :pointer (dirp :pointer))
#-darwin (defcfun readdir :pointer (dirp :pointer))

;; Use of reclen is generally fux0rd, so just count to the null
(defun dirent-name (ent)
  #-os-t-has-namlen
  (let* ((name (foreign-slot-value ent '(:struct foreign-dirent) 'd_name))
	 (len  (loop :with i = 0
		 :while (/= 0 (mem-aref name :unsigned-char i))
		 :do (incf i)
		 :finally (return i))))
    (foreign-string-to-lisp
     (foreign-slot-value ent '(:struct foreign-dirent) 'd_name)
     :count len))
  #+os-t-has-namlen
  (foreign-string-to-lisp
   (foreign-slot-value ent '(:struct foreign-dirent) 'd_name)
   :count (foreign-slot-value ent '(:struct foreign-dirent) 'd_namlen)))

(defun actual-file-type (dir)
  "Try to get the file type reported by 'stat' given a struct dirent."
  (handler-case
    (let ((s (stat (dirent-name dir))))
      (or (file-type-symbol (file-status-mode s)) :unknown))
    ;; Ignore access problems, but not other problems.
    (posix-error (c)
      (when (not (find (opsys-error-code c) `(,+ENOENT+ ,+EACCES+ ,+ENOTDIR+)))
	(signal c)))))

(defun dirent-type (ent)
  #+os-t-has-d-type
  (with-foreign-slots ((d_type) ent (:struct foreign-dirent))
    (cond
      ((= d_type DT_UNKNOWN)
       ;; Fix brokenness of some filesystems (e.g. NFS)
       ;; @@@ I supposed this might happen on other systems besides freebsd
       ;; but we should test and see, since it can make things much slower.
       #+freebsd (actual-file-type ent)
       #-freebsd :unknown
       )
      ((= d_type DT_FIFO)    :pipe)
      ((= d_type DT_CHR)     :character-device)
      ((= d_type DT_DIR)     :directory)
      ((= d_type DT_BLK)     :block-device)
      ((= d_type DT_REG)     :regular)
      ((= d_type DT_LNK)     :link)
      ((= d_type DT_SOCK)    :socket)
      ((= d_type DT_WHT)     :whiteout)
      (t :undefined)))
  #-os-t-has-d-type (declare (ignore ent))
  #-os-t-has-d-type :unknown)

;; This is really only for debugging.
(defun convert-dirent (ent)
  (with-foreign-slots ((d_ino) ent (:struct foreign-dirent))
    (make-dir-entry
     :name (dirent-name ent)
     :type (dirent-type ent)
     :inode d_ino)))

(defun dump-dirent (ent)
  (with-foreign-slots ((d_ino d_reclen d_type d_namlen d_name)
		       ent (:struct foreign-dirent))
    (format t "ino~20t~a~%"    d_ino)
    #+os-t-has-reclen (format t "reclen~20t~a~%" d_reclen)
    #+os-t-has-d-type (format t "type~20t~a~%"   d_type)
    #+os-t-has-namlen (format t "namlen~20t~a~%" d_namlen)
    (format t "name~20t~a~%"   d_name)))

;; If wanted, we could consider also doing "*" for executable. Of course
;; we would have the overhead of doing a stat(2).

#|
(defun tir ()
  "Test of opendir/readdir"
  (let* ((dirp (opendir "."))
	 ent p str quit-flag)
    (format t "dirp = ~a null = ~a~%" dirp (null-pointer-p dirp))
    (loop
       :until quit-flag
       :do
       (setf p (readdir dirp))
       (format t "p = ~a null = ~a~%" p (null-pointer-p p))
;       (setf ent (mem-ref p '(:pointer (:struct foreign-dirent-64))))
       (with-foreign-slots ((d_ino
			     #| d_seekoff |#
			     d_reclen
			     #+os-t-has-namlen d_namlen
			     d_type
			     d_name)
			    p (:struct foreign-dirent))
	 (format t "ino ~a" d_ino)
;;;	   (format t " seekoff ~a" d_seekoff)
	 (format t " reclen ~a" d_reclen)
	 #+os-t-has-namlen (format t " namlen ~a" d_namlen)
	 (format t " type ~a" d_type)
	 (format t " name ~a~%" d_name)
;	 (setf str (make-string d_namlen))
	 (setf str
	       (with-output-to-string (s)
		 (loop :with c = nil :and i = 0
;		    :for i :from 0 :below d_namlen
		    :while (not (zerop (setf c (mem-aref d_name :unsigned-char i))))
		    :do ;(format t "c=~a " c)
		    (when (> c 0)
		      (write-char (code-char c) s) (incf i)))))
	 (format t "\"~a\"~%" str))
       (when (equalp (read-line) "q")
	 (setf quit-flag t)))
    (closedir dirp)))
|#

(defun read-directory (&key dir append-type full omit-hidden)
  "Return a list of the file names in DIR as strings. DIR defaults to the ~
current directory. If APPEND-TYPE is true, append a character to the end of ~
the name indicating what type of file it is. Indicators are:
  / : directory
  @ : symbolic link
  | : FIFO (named pipe)
  = : Socket
  > : Doors
If FULL is true, return a list of dir-entry structures instead of file name ~
strings. Some dir-entry-type keywords are:
  :unknown :pipe :character-device :directory :block-device :regular :link
  :socket :whiteout :undefined
Be aware that DIR-ENTRY-TYPE type can't really be relied on, since many
systems return :UNKNOWN or something, when the actual type can be determined
by FILE-INFO-TYPE.
If OMIT-HIDDEN is true, do not include entries that start with ‘.’.
"
  (declare (type (or string null) dir) (type boolean append-type full))
  (when (not dir)
    (setf dir "."))
  (let ((dirp nil)
	(result 0)
	(dir-list nil))
    (unwind-protect
      (progn
	(if (null-pointer-p (setf dirp (opendir dir)))
	  (error 'posix-error :error-code *errno*
		 :format-control "opendir: ~a: ~a"
		 :format-arguments `(,dir ,(error-message *errno*)))
	  (progn
	    (with-foreign-objects ((ent '(:struct foreign-dirent))
				   (ptr :pointer))
	      (with-foreign-slots ((d_name
				    #+os-t-has-d-type d_type
				    d_ino)
				   ent (:struct foreign-dirent))
		(setf dir-list
		      (loop :while
			  (and (eql 0 (setf result (readdir_r dirp ent ptr)))
			       (not (null-pointer-p (mem-ref ptr :pointer))))
			 ;; :do (dump-dirent ent) ; @@@@@@ testing
			 :if (not (and omit-hidden
				       (hidden-file-name-p (dirent-name ent))))
			 :collect
			 (if full
			     (make-dir-entry
			      :name (dirent-name ent)
			      :type (dirent-type ent)
			      :inode d_ino)
			     ;; not full
			     (if append-type
				 #+os-t-has-d-type
				 (concatenate 'string (dirent-name ent)
					      (cond
						((= d_type DT_FIFO) "|")
						((= d_type DT_DIR)  "/")
						((= d_type DT_LNK)  "@")
						((= d_type DT_SOCK) "=")))
				 #-os-t-has-d-type (dirent-name ent)
				 (dirent-name ent)))))))
	    (when (not (= result 0))
	      (error 'posix-error :format-control "readdir"
		     :error-code *errno*)))))
      (when (not (null-pointer-p dirp))
	(syscall (closedir dirp))))
    dir-list))

(defmacro without-access-errors (&body body)
  "Evaluate the body while ignoring typical file access error from system
calls. Returns NIL when there is an error."
  `(handler-case
       (progn ,@body)
     (posix-error (c)
       (when (not (find (opsys-error-code c)
			`(,+ENOENT+ ,+EACCES+ ,+ENOTDIR+)))
	 (signal c)))))

(defcfun ("chroot" real-chroot) :int (dirname :string))
(defun chroot (dirname) (syscall (real-chroot dirname)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Files

#|
#+(or darwin freebsd linux)
(progn
  (defconstant +O_RDONLY+   #x0000 "Open for reading only")
  (defconstant +O_WRONLY+   #x0001 "Open for writing only")
  (defconstant +O_RDWR+	    #x0002 "Open for reading and writing")
  (defconstant +O_ACCMODE+  #x0003 "Mask for above modes")
  (defconstant +O_NONBLOCK+ #+(or darwin freebsd) #x0004 #+linux #o04000
	       "No delay")
  (defconstant +O_APPEND+   #+(or darwin freebsd) #x0008 #+linux #o02000
	       "Set append mode")
  (defconstant +O_ASYNC+    #+(or darwin freebsd) #x0040 #+linux #x020000
	       "Signal pgrp when data ready")
  (defconstant +O_SYNC+	    #+(or darwin freebsd) #x0080 #+linux #o04010000
	       "Synchronous writes")
  (defconstant +O_SHLOCK+   #x0010 "Atomically obtain a shared lock")
  (defconstant +O_EXLOCK+   #x0020 "Atomically obtain an exclusive lock")
  (defconstant +O_CREAT+    #+(or darwin freebsd) #x0200 #+linux #o100
	       "Create if nonexistant")
  (defconstant +O_TRUNC+    #+(or darwin freebsd) #x0400 #+linux #o01000
	       "Truncate to zero length")
  (defconstant +O_EXCL+	    #+(or darwin freebsd) #x0800 #+linux #o0200
	       "Error if create and already exists")
  (defconstant +O_NOCTTY+   #+darwin #x20000 #+linux #o0400 #+freebsd #x8000
	       "Don't assign controlling terminal"))
#+darwin
(defconstant +O_EVTONLY+  #x8000 "Requested for event notifications only")

#+linux
(progn
  (defconstant +O_LARGEFILE+ #o0100000)
  (defconstant +O_DIRECTORY+ #o0200000)
  (defconstant +O_NOFOLLOW+  #o0400000)
  (defconstant +O_DIRECT+    #o040000)
  (defconstant +O_NOATIME+   #o01000000)
  (defconstant +O_PATH+	     #o010000000)
  (defconstant +O_DSYNC+     #o010000)
  (defconstant +O_TMPFILE+   #o020200000))

#+freebsd
(progn
  (defconstant +O_NOFOLLOW+  #x00000100 "Don't follow symlinks")
  (defconstant +O_DIRECT+    #x00010000 "Attempt to bypass buffer cache")
  (defconstant +O_DIRECTORY+ #x00020000 "Fail if not directory")
  (defconstant +O_EXEC+	     #x00040000 "Open for execute only")
  (defconstant +O_FSYNC+     #x00000080 "Synchronous writes")
  (defconstant +O_TTY_INIT+  #x00080000 "Restore default termios attributes")
  (defconstant +O_CLOEXEC+   #x00100000))
|#

(defparameter *file-flags* nil "Flag for open and fcntl.")

#+(or darwin freebsd linux)
(define-to-list *file-flags*
  #(#(+O_RDONLY+   #x0000 "Open for reading only")
    #(+O_WRONLY+   #x0001 "Open for writing only")
    #(+O_RDWR+	   #x0002 "Open for reading and writing")
    #(+O_NONBLOCK+ #+(or darwin freebsd) #x0004 #+linux #o04000 "No delay")
    #(+O_APPEND+   #+(or darwin freebsd) #x0008 #+linux #o02000
      "Set append mode")
    #(+O_ASYNC+	   #+(or darwin freebsd) #x0040 #+linux #x020000
      "Signal pgrp when data ready")
    #(+O_SYNC+	   #+(or darwin freebsd) #x0080 #+linux #o04010000
      "Synchronous writes")
    #(+O_SHLOCK+   #x0010 "Atomically obtain a shared lock")
    #(+O_EXLOCK+   #x0020 "Atomically obtain an exclusive lock")
    #(+O_CREAT+	   #+(or darwin freebsd) #x0200 #+linux #o100
      "Create if nonexistant")
    #(+O_TRUNC+	   #+(or darwin freebsd) #x0400 #+linux #o01000
      "Truncate to zero length")
    #(+O_EXCL+	   #+(or darwin freebsd) #x0800 #+linux #o0200
      "Error if create and already exists")
    #(+O_NOCTTY+   #+darwin #x20000 #+linux #o0400 #+freebsd #x8000
      "Don't assign controlling terminal")))

#+(or darwin freebsd linux)
(defconstant +O_ACCMODE+ #x0003 "Mask for above modes")

#+darwin
(define-to-list *file-flags*
  #(#(+O_EVTONLY+ #x8000 "Requested for event notifications only")))

#+linux
(define-to-list *file-flags*
  #(#(+O_LARGEFILE+ #o000100000 "Crappy old fashioned work around.")
    #(+O_DIRECTORY+ #o000200000 "Fail if not directory")
    #(+O_NOFOLLOW+  #o000400000 "Don't follow symlinks")
    #(+O_DIRECT+    #o000040000 "Attempt to bypass buffer cache")
    #(+O_NOATIME+   #o001000000 "Don't update acess time")
    #(+O_PATH+      #o010000000 "Path bookmarking")
    #(+O_DSYNC+     #o000010000 "Data synchronization")
    #(+O_TMPFILE+   #o020200000 "Temporary anonymous")))

#+freebsd
(define-to-list *file-flags*
  #(#(+O_NOFOLLOW+  #x00000100 "Don't follow symlinks")
    #(+O_DIRECT+    #x00010000 "Attempt to bypass buffer cache")
    #(+O_DIRECTORY+ #x00020000 "Fail if not directory")
    #(+O_EXEC+	    #x00040000 "Open for execute only")
    #(+O_FSYNC+	    #x00000080 "Synchronous writes")
    #(+O_TTY_INIT+  #x00080000 "Restore default termios attributes")
    #(+O_CLOEXEC+   #x00100000 "Close on exec")))

(defcfun ("open"   posix-open)   :int (path :string) (flags :int) (mode mode-t))
(defcfun ("close"  posix-close)  :int (fd :int))
(defcfun ("read"   posix-read)   :int (fd :int) (buf :pointer) (nbytes size-t))
(defcfun ("write"  posix-write)  :int (fd :int) (buf :pointer) (nbytes size-t))
(defcfun ("ioctl"  posix-ioctl)  :int (fd :int) (request :int) (arg :pointer))
(defcfun ("unlink" posix-unlink) :int (path :string))

(defun simple-delete-file (path)
  "Delete a file."
  (syscall (posix-unlink (safe-namestring path))))

(defmacro with-posix-file ((var filename flags &optional (mode 0)) &body body)
  "Evaluate the body with the variable VAR bound to a posix file descriptor
opened on FILENAME with FLAGS and MODE."
  `(let (,var)
     (unwind-protect
       (progn
	 (setf ,var (posix-open ,filename ,flags ,mode))
	 ,@body)
       (if (>= ,var 0)
	   (posix-close ,var)
	   (error-check ,var)))))

(defmacro with-os-file ((var filename &key
			     (direction :input)
			     (if-exists :error)
			     (if-does-not-exist :error)) &body body)
  "Evaluate the body with the variable VAR bound to a posix file descriptor
opened on FILENAME. DIRECTION, IF-EXISTS, and IF-DOES-NOT-EXIST are simpler
versions of the keywords used in Lisp open.
  DIRECTION         - supports :INPUT, :OUTPUT, and :IO.
  IF-EXISTS         - supports :ERROR and :APPEND.
  IF-DOES-NOT-EXIST - supports :ERROR, and :CREATE.
"
  (let ((flags 0))
    (cond
      ((eq direction :input)    (setf flags +O_RDONLY+))
      ((eq direction :output)   (setf flags +O_WRONLY+))
      ((eq direction :io)       (setf flags +O_RDWR+))
      (t (error ":DIRECTION should be one of :INPUT, :OUTPUT, or :IO.")))
    (cond
      ((eq if-exists :append) (setf flags (logior flags +O_APPEND+)))
      ((eq if-exists :error) #| we cool |# )
      (t (error ":IF-EXISTS should be one of :ERROR, or :APPEND.")))
    (cond
      ((eq if-does-not-exist :create) (setf flags (logior flags +O_CREAT+)))
      ((eq if-does-not-exist :error) #| we cool |# )
      (t (error ":IF-DOES-NOT-EXIST should be one of :ERROR, or :CREATE.")))
    `(with-posix-file (,var ,filename ,flags)
       ,@body)))

(defcfun mkstemp :int (template :string))

;; what about ioctl defines?

#+(or darwin linux freebsd)
(progn
  (defconstant +F_DUPFD+	  0)
  (defconstant +F_DUPFD_CLOEXEC+  #+darwin 67 #+linux 1030 #+freebsd 17)
  (defconstant +F_GETFD+	  1)
  (defconstant +F_SETFD+	  2)
  (defconstant +F_GETFL+	  3)
  (defconstant +F_SETFL+	  4)
  (defconstant +F_GETOWN+	  #+(or darwin freebsd) 5 #+linux 9)
  (defconstant +F_SETOWN+	  #+(or darwin freebsd) 6 #+linux 8)
  (defconstant +F_GETLK+	  #+darwin 7 #+linux 5 #+freebsd 11)
  (defconstant +F_SETLK+	  #+darwin 8 #+linux 6 #+freebsd 12)
  (defconstant +F_SETLKW+	  #+darwin 9 #+linux 7 #+freebsd 13)
  (defconstant +FD_CLOEXEC+       1))

#+linux
(progn
  (defconstant +F_SETSIG+	   10 "Set number of signal to be sent.")
  (defconstant +F_GETSIG+	   11 "Get number of signal to be sent.")
  (defconstant +F_SETOWN_EX+	   15 "Get owner (thread receiving SIGIO).")
  (defconstant +F_GETOWN_EX+	   16 "Set owner (thread receiving SIGIO).")
  (defconstant +LOCK_MAND+	   32 "This is a mandatory flock:")
  (defconstant +LOCK_READ+	   64 ".. with concurrent read")
  (defconstant +LOCK_WRITE+	  128 ".. with concurrent write")
  (defconstant +LOCK_RW+	  192 ".. with concurrent read & write")
  (defconstant +F_SETLEASE+	 1024 "Set a lease.")
  (defconstant +F_GETLEASE+	 1025 "Enquire what lease is active.")
  (defconstant +F_NOTIFY+	 1026 "Request notifications on a directory.")
  (defconstant +F_SETPIPE_SZ+	 1031 "Set pipe page size array.")
  (defconstant +F_GETPIPE_SZ+	 1032 "Set pipe page size array.")
  ;; Types for F_NOTIFY
  (defconstant +DN_ACCESS+      #x00000001 "File accessed.")
  (defconstant +DN_MODIFY+      #x00000002 "File modified.")
  (defconstant +DN_CREATE+      #x00000004 "File created.")
  (defconstant +DN_DELETE+      #x00000008 "File removed.")
  (defconstant +DN_RENAME+      #x00000010 "File renamed.")
  (defconstant +DN_ATTRIB+      #x00000020 "File changed attributes.")
  (defconstant +DN_MULTISHOT+   #x80000000 "Don't remove notifier.")
  )

#+freebsd
(progn
  (defconstant +F_RDLCK+	   1  "Shared or read lock")
  (defconstant +F_UNLCK+	   2  "Unlock")
  (defconstant +F_WRLCK+	   3  "Exclusive or write lock")
  (defconstant +F_UNLCKSYS+	   4  "Purge locks for a given system ID")
  (defconstant +F_CANCEL+	   5  "Cancel an async lock request")
  (defconstant +F_DUP2FD+	   10 "Duplicate file descriptor to arg")
  (defconstant +F_SETLK_REMOTE+	   14 "Debugging support for remote locks")
  (defconstant +F_READAHEAD+	   15 "Read ahead")
  (defconstant +F_RDAHEAD+	   16 "Read ahead")
  (defconstant +F_DUPFD_CLOEXEC+   17 "Like F_DUPFD, but FD_CLOEXEC is set")
  (defconstant +F_DUP2FD_CLOEXEC+  18 "Like F_DUP2FD, but FD_CLOEXEC is set")
)

#+darwin
(progn
  (defconstant +F_RDAHEAD+		45)
  (defconstant +F_GETPATH+		50)
  (defconstant +F_PREALLOCATE+		42)
  (defconstant +F_SETSIZE+		43)
  (defconstant +F_RDADVISE+		44)
  (defconstant +F_READBOOTSTRAP+	46)
  (defconstant +F_WRITEBOOTSTRAP+	47)
  (defconstant +F_NOCACHE+		48)
  (defconstant +F_LOG2PHYS+		49)
  (defconstant +F_LOG2PHYS_EXT+		65)
  (defconstant +F_FULLFSYNC+		51)
  (defconstant +F_FREEZE_FS+		53)
  (defconstant +F_THAW_FS+		54)
  (defconstant +F_GLOBAL_NOCACHE+	55)
  (defconstant +F_ADDSIGS+		59)
  (defconstant +F_MARKDEPENDENCY+	60)
  (defconstant +F_ADDFILESIGS+		61)
  (defconstant +F_NODIRECT+		62)
  (defconstant +F_SETNOSIGPIPE+		73)
  (defconstant +F_GETNOSIGPIPE+		74)
  (defconstant +F_GETPROTECTIONCLASS+	63)
  (defconstant +F_SETPROTECTIONCLASS+	64)
  (defconstant +F_GETLKPID+		66)
  (defconstant +F_SETBACKINGSTORE+	70)
  (defconstant +F_GETPATH_MTMINFO+	71)
  (defconstant +F_ALLOCATECONTIG+	#x00000002)
  (defconstant +F_ALLOCATEALL+		#x00000004)
  (defconstant +F_PEOFPOSMODE+		3)
  (defconstant +F_VOLPOSMODE+		4))

(defcstruct flock
  "Advisory file segment locking data type."
  (l_start  off-t)			; Starting offset
  (l_len    off-t)			; len = 0 means until end of file
  (l_pid    pid-t)			; Lock owner
  (l_type   :short)			; Lock type: read/write, etc.
  (l_whence :short))			; Type of l_start

(defcstruct fstore
  "Used by F_DEALLOCATE and F_PREALLOCATE commands."
  (fst_flags :unsigned-int)		; IN: flags word
  (fst_posmode :int )			; IN: indicates use of offset field
  (fst_offset off-t)			; IN: start of the region
  (fst_length off-t)			; IN: size of the region
  (fst_bytesalloc off-t))		; OUT: number of bytes allocated

(defcstruct radvisory
  "Advisory file read data type"
  (ra_offset off-t)
  (ra_count :int))

(defcstruct fsignatures
  "Detached code signatures data type"
  (fs_file_start off-t)
  (fs_blob_start (:pointer :void))
  (fs_blob_size size-t))

(defcstruct fbootstraptransfer
  "Used by F_READBOOTSTRAP and F_WRITEBOOTSTRAP commands"
  (fbt_offset off-t)			; IN: offset to start read/write
  (fbt_length size-t)			; IN: number of bytes to transfer
  (fbt_buffer (:pointer :void)))	; IN: buffer to be read/written

(defcstruct log2phys
  "For F_LOG2PHYS and F_LOG2PHYS_EXT"
  (l2p_flags :unsigned-int)
  (l2p_contigbytes off-t)
  (l2p_devoffset off-t))

(defcfun fcntl :int (fd :int) (cmd :int) &rest)

(defun get-file-descriptor-flags (file-descriptor)
  "Return a list of the flags set on FILE-DESCRIPTOR."
  (let* ((flags   (fcntl file-descriptor +F_GETFL+))
	 (d-flags (fcntl file-descriptor +F_GETFD+))
	 result)
    ;; The others we can check if they're positive.
    (loop :for flag :in *file-flags*
       :if (plusp (logand (symbol-value flag) flags))
       :do (push flag result))

    ;; Need to special case this because it's usually defined as zero.
    (when (= (logand flags +O_ACCMODE+) +O_RDONLY+)
      (push '+O_RDONLY+ result))

    (when (plusp (logand d-flags +FD_CLOEXEC+))
      (push '+FD_CLOEXEC+ result))
    result))
	  
;; stat / lstat

;; st_mode bits
(defconstant		S_IFMT   #o0170000)	; type of file (mask)
(defconstant		S_IFIFO  #o0010000)	; named pipe (fifo)
(defconstant		S_IFCHR  #o0020000)	; character special
(defconstant		S_IFDIR  #o0040000)	; directory
(defconstant		S_IFNAM  #o0050000)	; XENIX named IPC
(defconstant		S_IFBLK  #o0060000)	; block special
(defconstant		S_IFREG  #o0100000)	; regular
(defconstant		S_IFLNK  #o0120000)	; symbolic link
(defconstant   		S_IFSOCK #o0140000)	; socket
#+sunos (defconstant	S_IFDOOR #o0150000)	; door
#+darwin  (defconstant	S_IFWHT  #o0160000)	; whiteout (obsolete)
#+sunos (defconstant	S_IFPORT #o0160000)	; event port

;; These should be the same on any POSIX
(defconstant S_ISUID #o0004000)	; set user id on execution
(defconstant S_ISGID #o0002000)	; set group id on execution
(defconstant S_ISVTX #o0001000)	; save swapped text even after use
(defconstant S_IRUSR #o0000400)	; read permission, owner
(defconstant S_IWUSR #o0000200)	; write permission, owner
(defconstant S_IXUSR #o0000100)	; execute/search permission, owner
(defconstant S_IRGRP #o0000040)	; read permission, group
(defconstant S_IWGRP #o0000020)	; write permission, group
(defconstant S_IXGRP #o0000010)	; execute/search permission, group
(defconstant S_IROTH #o0000004)	; read permission, other
(defconstant S_IWOTH #o0000002)	; write permission, other
(defconstant S_IXOTH #o0000001)	; execute/search permission, other

(defun is-user-readable    (mode) (/= (logand mode S_IRUSR) 0))
(defun is-user-writable    (mode) (/= (logand mode S_IWUSR) 0))
(defun is-user-executable  (mode) (/= (logand mode S_IXUSR) 0))
(defun is-group-readable   (mode) (/= (logand mode S_IRGRP) 0))
(defun is-group-writable   (mode) (/= (logand mode S_IWGRP) 0))
(defun is-group-executable (mode) (/= (logand mode S_IXGRP) 0))
(defun is-other-readable   (mode) (/= (logand mode S_IROTH) 0))
(defun is-other-writable   (mode) (/= (logand mode S_IWOTH) 0))
(defun is-other-executable (mode) (/= (logand mode S_IXOTH) 0))

(defun is-set-uid          (mode) (/= (logand mode S_ISUID) 0))
(defun is-set-gid          (mode) (/= (logand mode S_ISGID) 0))
(defun is-sticky           (mode) (/= (logand mode S_ISVTX) 0))

(defun is-fifo             (mode) (= (logand mode S_IFMT) S_IFIFO))
(defun is-character-device (mode) (= (logand mode S_IFMT) S_IFCHR))
(defun is-directory        (mode) (= (logand mode S_IFMT) S_IFDIR))
(defun is-block-device     (mode) (= (logand mode S_IFMT) S_IFBLK))
(defun is-regular-file     (mode) (= (logand mode S_IFMT) S_IFREG))
(defun is-symbolic-link    (mode) (= (logand mode S_IFMT) S_IFLNK))
(defun is-socket           (mode) (= (logand mode S_IFMT) S_IFSOCK))
(defun is-door 		   (mode)
  #+sunos (= (logand mode S_IFMT) S_IFDOOR)
  #-sunos (declare (ignore mode))
  )
(defun is-whiteout         (mode)
  #+darwin (= (logand mode S_IFMT) S_IFWHT)
  #-darwin (declare (ignore mode))
  )
(defun is-port             (mode)
  #+sunos (= (logand mode S_IFMT) S_IFPORT)
  #-sunos (declare (ignore mode))
  )

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defstruct file-type-info
    "Store data for file types."
    test
    symbol
    char
    name)

  (defmethod make-load-form ((s file-type-info) &optional environment)
    (make-load-form-saving-slots s :environment environment)))

(defparameter *file-type-data*
  (macrolet ((moo (test symbol char name)
	       (make-file-type-info
		:test test :symbol symbol :char char :name name)))
    (list
     (moo is-fifo	      :pipe		  #\F "FIFO")
     (moo is-character-device :character-device  #\c "character special")
     (moo is-directory	      :directory	  #\d "directory")
     (moo is-block-device     :block-device	  #\b "block special")
     (moo is-regular-file     :regular		  #\r "regular")
     (moo is-symbolic-link    :link		  #\l "symbolic link")
     (moo is-socket	      :socket		  #\s "socket")
     (moo is-door	      :door		  #\d "door")
     (moo is-whiteout	      :whiteout		  #\w "whiteout"))))

(defparameter *mode-tags*
  '((is-fifo		   	"FIFO")
    (is-character-device	"character special")
    (is-directory		"directory")
    (is-block-device		"block special")
    (is-regular-file		"regular")
    (is-symbolic-link		"symbolic link")
    (is-socket			"socket")
    (is-door			"door")
    (is-whiteout		"whiteout"))
  "Sequence of test functions and strings for printing modes.")

(defparameter *mode-tag-chars*
  '((is-fifo		   	#\p)
    (is-character-device	#\c)
    (is-directory		#\d)
    (is-block-device		#\b)
    (is-regular-file		#\-)
    (is-symbolic-link		#\l)
    (is-socket			#\s)
    (is-door		        #\D)
    (is-whiteout		#\w))
  "Sequence of test functions and strings for printing modes.")

(defparameter *permission-tags*
  '((is-user-readable		#\r)
    (is-user-writable		#\w)
    (is-user-executable		#\x)
    (is-group-readable		#\r)
    (is-group-writable		#\w)
    (is-group-executable	#\x)
    (is-other-readable		#\r)
    (is-other-writable		#\w)
    (is-other-executable	#\x))
  "Sequence of test functions and strings for printing permission bits.")

;; @@@ This is too slow
(defun file-type-char (mode)
  "Return the character representing the file type of MODE."
  (loop :for f :in *file-type-data* :do
     (when (funcall (file-type-info-test f) mode)
       (return-from file-type-char (file-type-info-char f)))))

;; @@@ This is too slow
(defun file-type-name (mode)
  "Return the character representing the file type of MODE."
  (loop :for f :in *file-type-data* :do
     (when (funcall (file-type-info-test f) mode)
       (return-from file-type-name (file-type-info-name f)))))

(defun file-type-symbol (mode)
  "Return the keyword representing the file type of MODE."
  (loop :for f :in *file-type-data* :do
     (when (funcall (file-type-info-test f) mode)
       (return-from file-type-symbol (file-type-info-symbol f)))))

(defun symbolic-mode (mode)
  "Convert a number to mode string. Like strmode."
  (with-output-to-string (stream)
    (loop :for (func chr) :in *mode-tag-chars*
       :do (when (apply func (list mode)) (princ chr stream)))

    (if (is-user-readable mode) (princ #\r stream) (princ #\- stream))
    (if (is-user-writable mode) (princ #\w stream) (princ #\- stream))
    (if (is-set-uid mode)
	(if (is-user-executable mode)
	    (princ #\s stream)
	    (princ #\S stream))
	(if (is-user-executable mode)
	    (princ #\x stream)
	    (princ #\- stream)))

    (if (is-group-readable mode) (princ #\r stream) (princ #\- stream))
    (if (is-group-writable mode) (princ #\w stream) (princ #\- stream))
    (if (is-set-gid mode)
	(if (is-group-executable mode)
	    (princ #\s stream)
	    (princ #\S stream))
	(if (is-group-executable mode)
	    (princ #\x stream)
	    (princ #\- stream)))

    (if (is-other-readable mode) (princ #\r stream) (princ #\- stream))
    (if (is-other-writable mode) (princ #\w stream) (princ #\- stream))
    (if (is-sticky mode)
	(if (is-other-executable mode)
	    (princ #\t stream)
	    (princ #\T stream))
	(if (is-other-executable mode)
	    (princ #\x stream)
	    (princ #\- stream)))))

;; Damnable file flags.
(defconstant UF_SETTABLE     #x0000ffff "Mask of owner changeable flags.")
(defconstant UF_NODUMP       #x00000001 "Do not dump file.")
(defconstant UF_IMMUTABLE    #x00000002 "File may not be changed.")
(defconstant UF_APPEND       #x00000004 "Writes to file may only append.")
(defconstant UF_OPAQUE       #x00000008 "Directory is opaque wrt. union.")
(defconstant UF_NOUNLINK     #x00000010 "File may not be removed or renamed.")
(defconstant UF_COMPRESSED   #x00000020 "File is hfs-compressed.")
(defconstant UF_TRACKED	     #x00000040
  "UF_TRACKED is used for dealing with document IDs. We no longer issue
  notifications for deletes or renames for files which have UF_TRACKED set.")
(defconstant UF_HIDDEN	     #x00008000
  "Hint that this item should not be displayed in a GUI.")
;;; Super-user changeable flags.
(defconstant SF_SETTABLE     #xffff0000 "Mask of superuser changeable flags.")
(defconstant SF_ARCHIVED     #x00010000 "File is archived.")
(defconstant SF_IMMUTABLE    #x00020000 "File may not be changed.")
(defconstant SF_APPEND	     #x00040000 "Writes to file may only append.")
(defconstant SF_RESTRICTED   #x00080000 "Restricted access.")
(defconstant SF_SNAPSHOT     #x00200000 "Snapshot inode.")

(defun flag-user-settable   (flag) (/= (logand flag UF_SETTABLE)   0))
(defun flag-user-nodump	    (flag) (/= (logand flag UF_NODUMP)	   0))
(defun flag-user-immutable  (flag) (/= (logand flag UF_IMMUTABLE)  0))
(defun flag-user-append	    (flag) (/= (logand flag UF_APPEND)	   0))
(defun flag-user-opaque	    (flag) (/= (logand flag UF_OPAQUE)	   0))
(defun flag-user-nounlink   (flag) (/= (logand flag UF_NOUNLINK)   0))
(defun flag-user-compressed (flag) (/= (logand flag UF_COMPRESSED) 0))
(defun flag-user-tracked    (flag) (/= (logand flag UF_TRACKED)	   0))
(defun flag-user-hidden	    (flag) (/= (logand flag UF_HIDDEN)	   0))
(defun flag-root-settable   (flag) (/= (logand flag SF_SETTABLE)   0))
(defun flag-root-archived   (flag) (/= (logand flag SF_ARCHIVED)   0))
(defun flag-root-immutable  (flag) (/= (logand flag SF_IMMUTABLE)  0))
(defun flag-root-append	    (flag) (/= (logand flag SF_APPEND)	   0))
(defun flag-root-restricted (flag) (/= (logand flag SF_RESTRICTED) 0))
(defun flag-root-snapshot   (flag) (/= (logand flag SF_SNAPSHOT)   0))

(defun flags-string (flags)
  (with-output-to-string (str)
    (when (flag-user-nodump     flags) (princ "nodump "		str))
    (when (flag-user-immutable  flags) (princ "uimmutable "	str))
    (when (flag-user-append     flags) (princ "uappend "	str))
    (when (flag-user-opaque     flags) (princ "opaque "		str))
    (when (flag-user-nounlink   flags) (princ "nounlink "	str))
    (when (flag-user-compressed flags) (princ "compressed "	str))
    (when (flag-user-tracked    flags) (princ "tracked "	str))
    (when (flag-user-hidden     flags) (princ "hidden "		str))

    (when (flag-root-archived   flags) (princ "archived "	str))
    (when (flag-root-immutable  flags) (princ "simmutable "	str))
    (when (flag-root-append     flags) (princ "sappend "	str))
    (when (flag-root-restricted flags) (princ "restricted "	str))
    (when (flag-root-snapshot   flags) (princ "snapshot "	str))))

 #|
;;; @@@ totally not done yet and messed up
(defun change-mode (orig-mode new-mode)
  "Change a mode by the symbolic mode changing syntax, as in chmod."
  (let ((result orig-mode) (i 0) user group others op)
    (labels ((change-one ()
	       (loop :with done
		  :while (not done)
		  :for c :in (subseq new-mode i) :do
		  (case c
		    (#\u (setf user t))
		    (#\u (setf group t))
		    ((#\o #\a) (setf others t))
		    (#\+ (setf op #'logior  done t))
		    (#\- (setf op #'logiand done t))
		    (#\= (setf op #'done t))
		    (t (error "Unknown permission type character '~c'." c)))
		  (incf i))
	       (loop :with done
		  :while (not done)
		  :for c :in (subseq new-mode i) :do
		  (case c
		    (#\r (setf (logior bits read)))
		    (#\w (setf (logior bits write)))
		    (#\x (setf (logior bits execute)))
		    (#\S (setf (logior bits sticky-group)))
		    (#\s (setf (logior bits sticky-user)))
		    (#\t (setf (logior bits sticky-others)))
		    (#\T (setf (logior bits sticky-???)))
		    (t (error "Unknown permission access character '~c'." c)))
		  (incf i))))
      (loop :do
	 (case (char new-mode i)
	   (#\space (incf i))
	   (#\, (incf i) (change-one)))
	 :while (and (not done) (< i (lentgh new-mode))))))
  )

(defun numeric-mode-offset (orig-mode new-mode)
  "Convert a symbolic mode offset string to a mode offset number."
  ;; @@@
  )

(defun symbolic-mask (mask)
  "Describe a change to a mode in symbolic mode syntax."
  )
|#

(defcstruct foreign-timespec
  (tv_sec  time-t)
  (tv_nsec :long))

(defstruct timespec
  seconds
  nanoseconds)

(defun convert-timespec (ts)
  (etypecase ts
    (foreign-pointer
     (if (null-pointer-p ts)
	 nil
	 (with-foreign-slots ((tv_sec tv_nsec) ts (:struct foreign-timespec))
	   (make-timespec :seconds tv_sec :nanoseconds tv_nsec))))
    (cons
     (make-timespec :seconds (getf ts 'tv_sec)
		    :nanoseconds (getf ts 'tv_nsec)))))

#+darwin (config-feature :os-t-has-birthtime)

#+old_obsolete_stat
(defcstruct foreign-stat
  (st_dev	dev-t)			; device inode resides on
  (st_ino	ino-t)			; inode's number
  (st_mode	mode-t)			; inode protection mode
  (st_nlink	nlink-t)		; number or hard links to the file
  (st_uid	uid-t)			; user-id of owner 
  (st_gid	gid-t)			; group-id of owner
  (st_rdev	dev-t)			; device type, for special file inode
  (st_atimespec (:struct foreign-timespec)) ; time of last access
  (st_mtimespec (:struct foreign-timespec)) ; time of last data modification
  (st_ctimespec (:struct foreign-timespec)) ; time of last file status change
  (st_size	off-t)			; file size, in bytes
  (st_blocks	quad-t)			; blocks allocated for file
  (st_blksize	#+darwin :int32		; optimal file sys I/O ops blocksize
		#-darwin :unsigned-long)
  (st_flags	:unsigned-long)		; user defined flags for file
  (st_gen	:unsigned-long)		; file generation number
)

#+(and darwin nil)
(defcstruct foreign-stat
  (st_dev	dev-t)			; device inode resides on
  (st_mode	mode-t)			; inode protection mode
  (st_nlink	nlink-t)		; number or hard links to the file
  (st_ino	ino-t)			; inode's number
  (st_uid	uid-t)			; user-id of owner 
  (st_gid	gid-t)			; group-id of owner
  (st_rdev	dev-t)			; device type, for special file inode
  (st_atimespec (:struct foreign-timespec)) ; time of last access
  (st_mtimespec (:struct foreign-timespec)) ; time of last data modification
  (st_ctimespec (:struct foreign-timespec)) ; time of last file status change
  (st_birthtimespec (:struct foreign-timespec)) ; time of last file status change
  (st_size	off-t)			; file size, in bytes
  (st_blocks	blkcnt-t)		; blocks allocated for file
  (st_blksize	blksize-t)		; optimal file sys I/O ops blocksize
  (st_flags	:uint32)		; user defined flags for file
  (st_gen	:uint32)		; file generation number
  (st_lspare	:int32)			; file generation number
  (st_qspare	:int64 :count 2)	; file generation number
)

#+darwin
(defcstruct foreign-stat
  (st_dev	dev-t)			; device inode resides on
  (st_mode	mode-t)			; inode protection mode
  (st_nlink	nlink-t)		; number or hard links to the file
  (st_ino	ino-t)			; inode's number
  (st_uid	uid-t)			; user-id of owner 
  (st_gid	gid-t)			; group-id of owner
  (st_rdev	dev-t)			; device type, for special file inode
  (st_atimespec (:struct foreign-timespec)) ; time of last access
  (st_mtimespec (:struct foreign-timespec)) ; time of last data modification
  (st_ctimespec (:struct foreign-timespec)) ; time of last file status change
  (st_birthtimespec (:struct foreign-timespec)) ; time of last file status change
  (st_size	off-t)			; file size, in bytes
  (st_blocks	blkcnt-t)		; blocks allocated for file
  (st_blksize	blksize-t)		; optimal file sys I/O ops blocksize
  (st_flags	:uint32)		; user defined flags for file
  (st_gen	:uint32)		; file generation number
  (st_lspare	:int32)			; unused
;  (st_qspare	:int64 :count 2)	; unused
  (st_qspare_1	:int64)			; unused
  (st_qspare_1	:int64)			; unused
)

;; 32bit stat -> __xstat -> fstatat64
;; 32bit ?    -> __xstat64 -> fstatat64

#+(and linux 32-bit-target (not cmu))
(defcstruct foreign-stat
  (st_dev	dev-t)			; ID of device containing file
  (__pad1	:unsigned-short)	;
  (st_ino	ino-t)			; 32 bit inode number **
  (st_mode	mode-t)			; protection
  (st_nlink	nlink-t)		; number of hard links
  (st_uid	uid-t)			; user ID of owner
  (st_gid	gid-t)			; group ID of owner
  (st_rdev	dev-t)			; device ID (if special file)
  (__pad2	:unsigned-short)	;
  (st_size	off-t)			; total size, in bytes **
  (st_blksize	blksize-t)		; blocksize for file system I/O
  (st_blocks	blkcnt-t)		; number of 512B blocks allocated **
  (st_atimespec	(:struct foreign-timespec)) ; time of last access
  (st_mtimespec	(:struct foreign-timespec)) ; time of last data modification
  (st_ctimespec	(:struct foreign-timespec)) ; time of last file status change
  (__unused4	:unsigned-long)
  (__unused5	:unsigned-long))

#+(and linux 32-bit-target cmu) ;; @@@ fixme
(defcstruct foreign-stat
  (st_dev	dev-t)			; ID of device containing file
  (__pad1	:unsigned-short)	;
  (__st_ino	:uint64 #|ino-t|#)      ; not inode number **
  (st_mode	mode-t)			; protection
  (st_nlink	:uint32 #|nlink-t|#)		; number of hard links
  (st_uid	uid-t)			; user ID of owner
  (st_gid	gid-t)			; group ID of owner
  (st_rdev	:uint64 #|dev-t|#)	; device ID (if special file)
  (__pad2	:unsigned-short)	;
  (st_size	:uint32 #| off-t |#)    ; total size, in bytes **
  (st_blksize	blksize-t)		; blocksize for file system I/O
  (st_blocks	blkcnt-t)		; number of 512B blocks allocated **
  (st_atimespec	(:struct foreign-timespec)) ; time of last access
  (st_mtimespec	(:struct foreign-timespec)) ; time of last data modification
  (st_ctimespec	(:struct foreign-timespec)) ; time of last file status change
  (st_ino	:uint64 #|ino-t|#)	; 64 bit inode number **
)

#+(and linux 64-bit-target some-version?)
(defcstruct foreign-stat
  (st_dev	dev-t)			; ID of device containing file
  (__pad1	:unsigned-short)	;
  (__st_ino	ino-t)			; NOT inode number **
  (st_mode	mode-t)			; protection
  (st_nlink	nlink-t)		; number of hard links
  (st_uid	uid-t)			; user ID of owner
  (st_gid	gid-t)			; group ID of owner
  (st_rdev	dev-t)			; device ID (if special file)
  (__pad2	:unsigned-short)	;
  (st_size	off-t)			; total size, in bytes **
  (st_blksize	blksize-t)		; blocksize for file system I/O
  (st_blocks	blkcnt-t)		; number of 512B blocks allocated **
  (st_atimespec	(:struct foreign-timespec)) ; time of last access
  (st_mtimespec	(:struct foreign-timespec)) ; time of last data modification
  (st_ctimespec	(:struct foreign-timespec)) ; time of last file status change
  (st_ino	ino-t)			; 64 bit inode number **
)

#+(and linux 64-bit-target)
(defcstruct foreign-stat
  (st_dev	dev-t)			; ID of device containing file
  (st_ino	ino-t)			; NOT inode number **
  (st_nlink	nlink-t)		; number of hard links
  (st_mode	mode-t)			; protection
  (st_uid	uid-t)			; user ID of owner
  (st_gid	gid-t)			; group ID of owner
  (__pad0	:int)			;
  (st_rdev	dev-t)			; device ID (if special file)
  (st_size	off-t)			; total size, in bytes **
  (st_blksize	blksize-t)		; blocksize for file system I/O
  (st_blocks	blkcnt-t)		; number of 512B blocks allocated **
  (st_atimespec	(:struct foreign-timespec)) ; time of last access
  (st_mtimespec	(:struct foreign-timespec)) ; time of last data modification
  (st_ctimespec	(:struct foreign-timespec)) ; time of last file status change
  (__glibc_reserved :long :count 3)
)

#+(and freebsd 64-bit-target)
(defcstruct foreign-stat
  (st_dev 	dev-t)
  (st_ino 	ino-t)
  (st_mode 	mode-t)
  (st_nlink 	nlink-t)
  (st_uid 	uid-t)
  (st_gid 	gid-t)
  (st_rdev 	dev-t)
  (st_atimespec	(:struct foreign-timespec)) ;; st_atim
  (st_mtimespec	(:struct foreign-timespec)) ;; st_mtim
  (st_ctimespec	(:struct foreign-timespec)) ;; st_ctim
  (st_size	off-t)
  (st_blocks	blkcnt-t)
  (st_blksize	blksize-t)
  (st_flags	fflags-t)
  (st_gen	:uint32)
  (st_lspare	:int32)
  (st_birthtim  (:struct foreign-timespec))
  (junk		:uint8 :count 8))

;;  (unsigned int :(8 / 2) * (16 - (int)sizeof(struct timespec))
;;  (unsigned int :(8 / 2) * (16 - (int)sizeof(struct timespec))

;; This should have the union of all Unix-like OS's slots, so that Unix
;; portable code can check for specific slots with impunity.
(defstruct file-status
  device
  inode
  (mode 0 :type integer)
  links
  (uid -1 :type integer)
  (gid -1 :type integer)
  device-type
  access-time
  modify-time
  change-time
  birth-time
  size
  blocks
  block-size
  flags
  generation)

(defun convert-stat (stat-buf)
  (if (and (pointerp stat-buf) (null-pointer-p stat-buf))
      nil
      (with-foreign-slots
	  ((st_dev
	    st_ino
	    st_mode
	    st_nlink
	    st_uid
	    st_gid
	    st_rdev
	    st_atimespec
	    st_mtimespec
	    st_ctimespec
	    #+os-t-has-birthtime st_birthtimespec
	    st_size
	    st_blocks
	    st_blksize
	    #+darwin st_flags
	    #+darwin st_gen
	    ) stat-buf (:struct foreign-stat))
	   (make-file-status
	    :device st_dev
	    :inode st_ino
	    :mode st_mode
	    :links st_nlink
	    :uid st_uid
	    :gid st_gid
	    :device-type st_rdev
	    :access-time (convert-timespec st_atimespec)
	    :modify-time (convert-timespec st_mtimespec)
	    :change-time (convert-timespec st_ctimespec)
	    #+os-t-has-birthtime :birth-time
	    #+os-t-has-birthtime (convert-timespec st_birthtimespec)
	    :size st_size
	    :blocks st_blocks
	    :block-size st_blksize
	    #+darwin :flags #+darwin st_flags
	    #+darwin :generation #+darwin st_gen
	    ))))

;; Here's the real stat functions in glibc on linux:
;; GLIBC_2.2.5 __xstat
;; GLIBC_2.2.5 __xstat64
;; GLIBC_2.2.5 __fxstat
;; GLIBC_2.2.5 __fxstat64
;; GLIBC_2.2.5 __lxstat
;; GLIBC_2.2.5 __lxstat64
;; GLIBC_2.4   __fxstatat
;; GLIBC_2.4   __fxstatat64

#+(and linux (or sbcl #|cmu|#)) ;; I'm not really sure how this works.
(progn
  (defcfun ("stat" real-stat)
      :int (path :string) (buf (:pointer (:struct foreign-stat))))

  (defcfun ("lstat" real-lstat)
      :int (path :string) (buf (:pointer (:struct foreign-stat))))

  (defcfun ("fstat" real-fstat)
      :int (fd :int) (buf (:pointer (:struct foreign-stat)))))

(defparameter *stat-version*
  #+64-bit-target 0
  #+32-bit-target 3
  )

;; We have to do the wack crap.
#+(and linux (and (not sbcl) #|(not cmu)|#))
(progn
  (defcfun ("__xstat"  completely-fucking-bogus-but-actually-real-stat)
      :int (vers :int) (path :string) (buf (:pointer (:struct foreign-stat))))
  (defcfun ("__lxstat" completely-fucking-bogus-but-actually-real-lstat)
      :int (vers :int) (path :string) (buf (:pointer (:struct foreign-stat))))
  (defcfun ("__fxstat" completely-fucking-bogus-but-actually-real-fstat)
      :int (vers :int) (fd :int) (buf (:pointer (:struct foreign-stat))))
  (defun real-stat (path buf)
    (completely-fucking-bogus-but-actually-real-stat  *stat-version* path buf))
  (defun real-lstat (path buf)
    (completely-fucking-bogus-but-actually-real-lstat *stat-version* path buf))
  (defun real-fstat (path buf)
    (completely-fucking-bogus-but-actually-real-fstat *stat-version* path buf)))

#-linux ;; so mostly BSDs
(progn
  (defcfun
    (#+darwin "stat$INODE64"
     #-darwin "stat"
     real-stat)
    :int (path :string) (buf (:pointer (:struct foreign-stat))))

  (defcfun
    (#+darwin "lstat$INODE64"
     #-darwin "lstat"
     real-lstat)
    :int (path :string) (buf (:pointer (:struct foreign-stat))))

  (defcfun
    (#+darwin "fstat$INODE64"
     #-darwin "fstat"
     real-fstat)
    :int (fd :int) (buf (:pointer (:struct foreign-stat)))))

(defun stat (path)
  (with-foreign-object (stat-buf '(:struct foreign-stat))
    (error-check (real-stat path stat-buf) "stat: ~s" path)
    (convert-stat stat-buf)))

(defun lstat (path)
  (with-foreign-object (stat-buf '(:struct foreign-stat))
    (error-check (real-lstat path stat-buf) "lstat: ~s" path)
    (convert-stat stat-buf)))

(defun fstat (path)
  (with-foreign-object (stat-buf '(:struct foreign-stat))
    (error-check (real-fstat path stat-buf) "fstat: ~s" path)
    (convert-stat stat-buf)))

(defvar *statbuf* nil
  "Just some space to put file status in. It's just to make file-exists, 
quicker. We don't care what's in it.")

;; Sadly I find the need to do this because probe-file might be losing.
(defun file-exists (filename)
  "Check that a file with FILENAME exists at the moment. But it might not exist
for long."
  ;; (when (not (stringp (setf filename (safe-namestring filename))))
  ;;   (error "FILENAME should be a string or pathname."))
  (when (not *statbuf*)
    (setf *statbuf* (foreign-alloc '(:struct foreign-stat))))
  (= 0 (real-stat (safe-namestring filename) *statbuf*)))

(defcfun ("readlink" real-readlink) ssize-t (path :string)
	 (buf (:pointer :char)) (bufsize size-t))

(defun readlink (filename)
  "Return the name which the symbolic link FILENAME points to. Return NIL if
it is not a symbolic link."
  (with-foreign-pointer (buf (1+ (get-path-max)))
    (let ((result (real-readlink filename buf (get-path-max))))
      (if (> result 0)
	  (subseq (foreign-string-to-lisp buf :count result) 0 result)
	  (let ((err *errno*))		; in case there are hidden syscalls
	    (if (= err +EINVAL+)
		nil
		(error 'posix-error :error-code err
		       :format-control "readlink:")))))))

(defun timespec-to-derptime (ts)
  "Convert a timespec to a derptime."
  (make-derp-time
   :seconds (unix-to-universal-time (getf ts 'tv_sec))
   :nanoseconds (getf ts 'tv_nsec)))

(defun convert-file-info (stat-buf)
  (if (and (pointerp stat-buf) (null-pointer-p stat-buf))
      nil
      (with-foreign-slots
	  ((st_mode
	    st_atimespec
	    st_mtimespec
	    st_ctimespec
	    #+os-t-has-birthtime st_birthtimespec
	    st_size
	    #+darwin st_flags
	    ) stat-buf (:struct foreign-stat))
	(make-file-info
	 :type (cond
		 ;; We should have this be the same as DIRENT-TYPE
		 ((is-directory st_mode)		:directory)
		 ((is-symbolic-link st_mode)		:link)
		 ((or (is-character-device st_mode)
		      (is-block-device st_mode)) 	:device)
		 ((is-regular-file st_mode) 		:regular)
		 (t					:other))
	 :size st_size
	 :creation-time
	 ;; perhaps should be the earliest of st_ctimespec and st_birthtimespec?
	 (timespec-to-derptime
	  #+os-t-has-birthtime st_birthtimespec
	  #-os-t-has-birthtime st_mtimespec)
	 :access-time (timespec-to-derptime st_atimespec)
	 :modification-time
	 ;; perhaps should be the latest of st_ctimespec and st_mtimespec?
	 (timespec-to-derptime st_ctimespec)
	 :flags
	 ;; :hidden :immutable :compressed
	 `(
	   #+darwin ,@(and (or (flag-user-immutable st_flags)
			       (flag-root-immutable st_flags))
			   (list :immutable))
	   #+darwin ,@(and (flag-user-compressed st_flags)
			   (list :compressed))
	   #+darwin ,@(and (flag-user-hidden st_flags)
			   (list :hidden))
	   ;; linux ext flags are so lame I can't be bothered to do them now.
	   )))))

(defun get-file-info (path &key (follow-links t))
  (with-foreign-object (stat-buf '(:struct foreign-stat))
    (error-check (if follow-links
		     (real-stat path stat-buf)
		     (real-lstat path stat-buf)) "get-file-info: ~s" path)
    (convert-file-info stat-buf)))

;; Supposedly never fails so we don't have to wrap with syscall.
;; @@@ consider taking symbolic string arguments
(defcfun umask mode-t (cmask mode-t))

(defcfun ("chmod" real-chmod) :int (path :string) (mode mode-t))
(defun chmod (path mode)
  "Change the mode (a.k.a. permission bits) of a file."
  ;; @@@ take the symbolic mode forms when we're done with the above
  (syscall (real-chmod path mode)))

(defcfun ("fchmod" real-fchmod) :int (fd :int) (mode mode-t))
(defun fchmod (fd mode)
  "Change the mode (a.k.a. permission bits) of a file."
  ;; @@@ take the symbolic mode forms when we're done with the above
  (syscall (real-fchmod fd mode)))

(defcfun ("chown" real-chown) :int (path :string) (owner uid-t) (group gid-t))
(defun chown (path owner group)
  "Change the owner and group of a file."
  ;; @@@ take string owner and group and convert to numeric
  (syscall (real-chown path owner group)))

(defcfun ("fchown" real-fchown) :int (fd :int) (owner uid-t) (group gid-t))
(defun fchown (fd owner group)
  "Change the owner and group of a file given a file descriptor."
  ;; @@@ take string owner and group and convert to numeric
  (syscall (real-fchown fd owner group)))

(defcfun ("lchown" real-lchown)
    :int (path :string) (owner uid-t) (group gid-t))
(defun lchown (path owner group)
  "Change the owner and group of a symbolic link (not what it points to)."
  ;; @@@ take string owner and group and convert to numeric
  (syscall (real-lchown path owner group)))

;; This is sadly still actually useful.
(defcfun sync :void)

;; @@@ I should probably make all implementations use my code, so things behave
;; uniformly, especially with regards to errors, but first it should tested.
(defun probe-directory (dir)
  "Something like probe-file but for directories."
  ;; #+clisp (ext:probe-directory (make-pathname
  ;; 				:directory (ext:absolute-pathname dir)))
  #+(or sbcl ccl cmu clisp ecl)
  ;; Let's be more specific: it must be a directory.
  (handler-case
    (let ((s (stat dir)))
      (and (is-directory (file-status-mode s))))
    (posix-error (c)
      (when (not (find (opsys-error-code c) `(,+ENOENT+ ,+EACCES+ ,+ENOTDIR+)))
	(signal c))))
  #+(or lispworks abcl)
  ;; On some implementations probe-file can handle directories the way I want.
  (probe-file dir)
  #-(or clisp sbcl ccl cmu ecl lispworks abcl)
  (declare (ignore dir))
  #-(or clisp sbcl ccl cmu ecl lispworks abcl)
  (missing-implementation 'probe-directory))

;; File locking? : fcntl F_GETLK / F_GETLK F_SETLKW

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Stupid file locking
;;
;; Supposedly making a directory is atomic even on shitty networked
;; filesystems. NOT thread safe, yet.

(defvar *lock-suffix* ".lck"
  "What to append to a path to make the lock name.")

(defun lock-file-name (pathname)
  "Return the name of the lock file for PATHNAME."
  ;; (path-append (or (path-directory-name pathname) "")
  ;; 	       (concatenate 'string (path-file-name pathname) *lock-suffix*))
  (s+ pathname *lock-suffix*))

(defun lock-file (pathname lock-type timeout increment)
  "Lock PATHNAME."
  (declare (ignore lock-type))
  ;; @@@ perhaps we should add u+x, even though it's mostly pointless,
  ;; but just so things that traverse the filesystem won't get stupid
  ;; permission errors.
  (let ((mode (file-status-mode (stat (safe-namestring pathname))))
	(filename (lock-file-name pathname))
	(time 0.0)
	(f-timeout (float timeout)))
    (declare (type single-float time f-timeout))
    ;; Very lame and slow polling.
    (loop :with wait :and inc single-float = (float increment)
       :do
       (if (not (ignore-errors (make-directory filename :mode mode)))
	   (if (= *errno* +EEXIST+) ;; @@@ unix specific!
	       (setf wait t)
	       (error-check -1 "lock-file: ~s" filename))
	   (setf wait nil))
       ;; (when wait
       ;; 	 (format t "Waiting...~d~%" time))
       :while (and wait (< time f-timeout))
       :do (sleep inc) (incf time inc))
    (when (>= time f-timeout)
      (error "Timed out trying to lock file ~s" pathname)))
  t)

(defun unlock-file (pathname)
  "Unlock PATHNAME."
  (let ((filename (lock-file-name (safe-namestring pathname))))
    (when (file-exists filename)
      (delete-directory filename)
      ;; (format t "Unlocked~%")
      (sync))))

(defmacro with-locked-file ((pathname &key (lock-type :write) (timeout 3)
				      (increment .1))
			    &body body)
  "Evaluate BODY with PATHNAME locked. Only wait for TIMEOUT seconds to get a
lock, checking at least every INCREMNT seconds."
  ;; @@@ Need to wrap with recursive thread locks
  (with-unique-names (locked)
    `(let ((,locked nil))
       (unwind-protect
	    (progn
	      (setf ,locked
		    (lock-file ,pathname ,lock-type ,timeout ,increment))
	      ,@body)
	 (when ,locked
	   (unlock-file ,pathname))))))

(defcfun ("utimensat" real-utimensat) :int
  (dirfd :int) (pathname :string)
  (times (:pointer (:struct foreign-timespec))) ; struct timespec times[2]
  (flags :int))

#|
(defun set-file-time (path &key seconds nanoseconds)
  (let (dir-fd
	
    (unwind-protect
      (setf dir-fd (posix-open 
  (syscall (real-utimensat
  )
|#

;; Apple metadata crap:
;; searchfs
;; getdirentriesattr
;;
;; Look into file metadata libraries? which will work on windows, etc..

;; OSX extended attributes

(defconstant +XATTR_NOFOLLOW+		#x0001)
(defconstant +XATTR_CREATE+		#x0002)
(defconstant +XATTR_REPLACE+		#x0004)
(defconstant +XATTR_NOSECURITY+		#x0008)
(defconstant +XATTR_NODEFAULT+		#x0010)
(defconstant +XATTR_SHOWCOMPRESSION+	#x0020)
(defconstant +XATTR_MAXNAMELEN+		127)

;; @@@ Maybe these *are* on linux?
#+darwin
(progn
  (defcfun listxattr ssize-t (path :string) (namebuff :string) (size size-t)
	   (options :int))
  (defcfun flistxattr ssize-t (fd :int) (namebuff :string) (size size-t)
	   (options :int))
  (defcfun getxattr ssize-t (path :string) (name :string) (value :pointer)
	   (size size-t) (position :uint32) (options :int))
  (defcfun fgetxattr ssize-t (fd :int) (name :string) (value :pointer)
	   (size size-t) (position :uint32) (options :int))
  (defcfun setxattr :int (path :string) (name :string) (value :pointer)
	   (size size-t) (position :uint32) (options :int))
  (defcfun fsetxattr :int (fd :int) (name :string) (value :pointer)
	   (size size-t) (position :uint32) (options :int))
  (defcfun removexattr :int (path :string) (name :string) (options :int))
  (defcfun fremovexattr :int (fd :int) (name :string) (options :int)))

;; These are defined, but just don't return anything on non-Darwin.

(defun extended-attribute-list (path)
  #+darwin
  (let ((size (listxattr path (null-pointer) 0 0))
	names)
    (with-foreign-object (f-names :char size)
      (syscall (listxattr path f-names size +XATTR_SHOWCOMPRESSION+))
      (setf names (foreign-string-to-lisp f-names :count size))
      (loop :with i = 0 :and end
	 :while (< i size)
	 :do
	 (setf end (position (code-char 0) names :start i))
	 :when (and end (< (+ i end) size))
	 :collect (subseq names i end)
	 :do (incf i end))))
  #-darwin (declare (ignore path))
  #-darwin '())

(defun extended-attribute-value (path name)
  #+darwin
  (let ((size (getxattr path name (null-pointer) 0 0 0)))
    (with-foreign-object (value :char size)
      (syscall (getxattr path name value size 0 +XATTR_SHOWCOMPRESSION+))
      value))
  #-darwin (declare (ignore path name))
  #-darwin nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; System Commands?

(defun is-executable (thing &key user regular)
  "Return true if the THING is executable by the UID. UID defaults to the
current effective user. THING can be a path or a FILE-STATUS structure."
  (let ((s (or (and (file-status-p thing) thing) (stat thing))))
    (and
     (or
      (is-other-executable (file-status-mode s))
      (and (is-user-executable (file-status-mode s))
	   (= (file-status-uid s) (or user (setf user (geteuid)))))
      (and (is-group-executable (file-status-mode s))
	   (member-of (file-status-gid s))))
     (or (not regular)
	 (is-regular-file (file-status-mode s))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Application paths

(defun expand-leading-tilde (filename)
  "Return FILENAME with a leading tilde converted into the users home directory."
  (if (and filename (stringp filename) (not (zerop (length filename)))
	   (char= (char filename 0) #\~))
      (s+ (or (environment-variable "HOME") (user-home))
	  "/" (subseq filename 2))	; XXX wrongish
      filename))

;; This is mostly from:
;;   https://specifications.freedesktop.org/basedir-spec/latest/

#+(or linux sunos freebsd) ;; I'm not sure about sunos and freebsd.
(progn
  (defun xdg-thing (env-var default)
    "Return the the ENV-VAR or if it's not set or empty then the DEFAULT."
    (let ((result (or (let ((e (environment-variable env-var)))
			(and e (not (zerop (length e))) e))
		      default)))
      ;; It might be nice if we could use glob:expand-tilde, but we can't.
      ;; I supposed we could move it here though.
      (expand-leading-tilde result)))

  (defun xdg-app-dir (env-var default &optional app-name)
    "Return the the ENV-VAR or if it's not set or empty then the DEFAULT.
If APP-NAME is given, append that."
    (let ((result (xdg-thing env-var default)))
      (or (and app-name (s+ result "/" app-name))
	  result)))

  (defun xdg-path (env-var default &optional app-name)
    "Return the ENV-VAR or DEFAULT path as a list, possibily with app-name
appended to each element."
    (let ((result (split-sequence #\: (xdg-thing env-var default))))
      (or (and app-name (mapcar (_ (s+ _ "/" app-name)) result))
	  result)))

  (defparameter *default-data-dir* "~/.local/share")
  (defparameter *data-dir-env-var* "XDG_DATA_HOME")
  (defun data-dir (&optional app-name)
    "Where user specific data files should be stored."
    (xdg-app-dir *data-dir-env-var* *default-data-dir* app-name))

  (defparameter *default-config-dir* "~/.config")
  (defparameter *config-dir-env-var* "XDG_CONFIG_HOME")
  (defun config-dir (&optional app-name)
    "Where user specific configuration files should be stored."
    (xdg-app-dir *config-dir-env-var* *default-config-dir* app-name))

  (defparameter *default-data-path* "/usr/local/share/:/usr/share/")
  (defparameter *data-path-env-var* "XDG_DATA_DIRS")
  (defun data-path (&optional app-name)
    "Search path for user specific data files."
    (cons (data-dir app-name)
	  (xdg-path *data-path-env-var* *default-data-path* app-name)))

  (defparameter *default-config-path* "/etc/xdg")
  (defparameter *config-path-env-var* "XDG_CONFIG_DIRS")
  (defun config-path (&optional app-name)
    "Search path for user specific configuration files."
    (cons (config-dir app-name)
	  (xdg-path *config-path-env-var* *default-config-path* app-name)))

  (defparameter *default-cache-dir* "~/.cache")
  (defparameter *cache-dir-env-var* "XDG_CACHE_HOME")
  (defun cache-dir (&optional app-name)
    "Directory where user specific non-essential data files should be stored."
    (xdg-app-dir *cache-dir-env-var* *default-cache-dir* app-name))

  ;; Runtime dir has a lot of special restrictions. See the XDG spec.
  (defparameter *default-runtime-dir* "/run/user")
  (defparameter *runtime-dir-env-var* "XDG_RUNTIME_DIR")
  (defun runtime-dir (&optional app-name)
    "Directory where user-specific non-essential runtime files and other file
objects should be stored."
    (xdg-app-dir *runtime-dir-env-var*
		 (s+ *default-runtime-dir* #\/ (getuid)) app-name)))

#+darwin
(progn
  ;; @@@ I know this is all wrong.
  
  (defparameter *default-app* "Lisp")
  (defun data-dir (&optional app-name)
    "Where user specific data files should be stored."
    (declare (ignore app-name))
    (expand-leading-tilde "~/Documents")) ;; @@@ or translation
  
  (defun config-dir (&optional app-name)
    "Where user specific configuration files should be stored."
    (s+ (expand-leading-tilde "~/Library/Application Support")
	"/" (or app-name *default-app*)))

  (defun data-path (&optional app-name)
    "Search path for user specific data files."
    (list (data-dir app-name)))

  (defun config-path (&optional app-name)
    "Search path for user specific configuration files."
    (list (config-dir app-name)))

  (defun cache-dir (&optional app-name)
    "Directory where user specific non-essential data files should be stored."
    (s+ (expand-leading-tilde "~/Library/Caches") "/"
	(or app-name *default-app*)))

  (defun runtime-dir (&optional app-name)
    "Directory where user-specific non-essential runtime files and other file
objects should be stored."
    ;; @@@ This is totally wrong. I know there's some long number in here.
    (s+ "/var/run" "/" (getuid) "/" app-name)))

;; I feel like I'm already in the past.

;; statfs

#+(and darwin (not 64-bit-target))
(eval-when (:compile-toplevel :load-toplevel :execute)
   (define-constant +MFSNAMELEN+ 15)	; length of fs type name, not inc. nul
   (define-constant +MNAMELEN+ 90)	; length of buffer for returned name
   (define-constant +MFSTYPENAMELEN+ +MFSNAMELEN+)
   (define-constant +MAXPATHLEN+ +MNAMELEN+)
)

;; when _DARWIN_FEATURE_64_BIT_INODE is NOT defined
#+(and darwin (not 64-bit-target))
(defcstruct foreign-statfs
  (f_otype	 :short)          ; type of file system (reserved: zero)
  (f_oflags	 :short)	  ; copy of mount flags (reserved: zero)
  (f_bsize	 :long)		  ; fundamental file system block size
  (f_iosize	 :long)		  ; optimal transfer block size
  (f_blocks	 :long)		  ; total data blocks in file system
  (f_bfree	 :long)		  ; free blocks in fs
  (f_bavail	 :long)		  ; free blocks avail to non-superuser
  (f_files	 :long)		  ; total file nodes in file system
  (f_ffree	 :long)		  ; free file nodes in fs
;  (f_fsid fsid_t)		  ; file system id
  (f_fsid	 :int32 :count 2) ; file system id
  (f_owner uid-t)		  ; user that mounted the file system
  (f_reserved1	 :short)	  ; reserved for future use
  (f_type	 :short)	  ; type of file system (reserved)
  (f_flags	 :long)		  ; copy of mount flags (reserved)
  (f_reserved2	 :long :count 2)  ; reserved for future use
  (f_fstypename	 :char :count #.+MFSNAMELEN+) ; fs type name
  (f_mntonname	 :char :count #.+MNAMELEN+)   ; directory on which mounted
  (f_mntfromname :char :count #.+MNAMELEN+)   ; mounted file system
  (f_reserved3	 :char)		  ; reserved for future use
  (f_reserved4	 :long :count 4)  ; reserved for future use
  )

#+(and darwin 64-bit-target)
(eval-when (:compile-toplevel :load-toplevel :execute)
   (define-constant +MFSTYPENAMELEN+ 16); length of fs type name, including nul
   (define-constant +MAXPATHLEN+ 1024)	; length of buffer for returned name
)

#+(and darwin 64-bit-target)
;; when _DARWIN_FEATURE_64_BIT_INODE *is* defined
(defcstruct foreign-statfs
  (f_bsize       :uint32)		; fundamental file system block size
  (f_iosize	 :int32)		; optimal transfer block size
  (f_blocks	 :uint64)		; total data blocks in file system
  (f_bfree	 :uint64)		; free blocks in fs
  (f_bavail	 :uint64)		; free blocks avail to non-superuser
  (f_files	 :uint64)		; total file nodes in file system
  (f_ffree	 :uint64)		; free file nodes in fs
;  (f_fsid fsid_t)			; file system id
  (f_fsid	 :int32  :count 2)	; file system id
  (f_owner       uid-t)			; user that mounted the file system
  (f_type        :uint32)		; type of file system
  (f_flags       :uint32)		; copy of mount flags
  (f_fssubtype   :uint32)		; fs sub-type (flavor)
  (f_fstypename  :char   :count #.+MFSTYPENAMELEN+) ; fs type name
  (f_mntonname   :char   :count #.+MAXPATHLEN+)	    ; directory on which mounted
  (f_mntfromname :char   :count #.+MAXPATHLEN+)	    ; mounted file system
  (f_reserved4   :uint32 :count 8)      ; reserved for future use
  )

#+darwin
(defstruct statfs
  "File system statistics."
  bsize
  iosize
  blocks
  bfree
  bavail
  files
  ffree
  fsid
  owner
  type
  flags
  fssubtype
  fstypename
  mntonname
  mntfromname)

;; @@@ I shouldn't really have to do this?
#+darwin
(defun convert-statfs (statfs)
  (if (and (pointerp statfs) (null-pointer-p statfs))
      nil
      (with-foreign-slots ((f_bsize
			    f_iosize
			    f_blocks
			    f_bfree
			    f_bavail
			    f_files
			    f_ffree
			    f_fsid
			    f_owner
			    f_type
			    f_flags
			    #+64-bit-target f_fssubtype
			    f_fstypename
			    f_mntonname
			    f_mntfromname) statfs (:struct foreign-statfs))
	(make-statfs
	 :bsize f_bsize
	 :iosize f_iosize
	 :blocks f_blocks
	 :bfree f_bfree
	 :bavail f_bavail
	 :files f_files
	 :ffree f_ffree
	 :fsid (vector (mem-aref f_fsid :int32 0) (mem-aref f_fsid :int32 1))
	 :owner f_owner
	 :type f_type
	 :flags f_flags
	 #+64-bit-target :fssubtype #+64-bit-target f_fssubtype
	 :fstypename (foreign-string-to-lisp f_fstypename
					     :max-chars +MFSTYPENAMELEN+)
	 :mntonname (foreign-string-to-lisp f_mntonname
					     :max-chars +MAXPATHLEN+)
	 :mntfromname (foreign-string-to-lisp f_mntfromname
					     :max-chars +MAXPATHLEN+)))))

#+darwin
(defun convert-filesystem-info (statfs)
  (if (and (pointerp statfs) (null-pointer-p statfs))
      nil
      (with-foreign-slots ((f_bsize
			    f_iosize
			    f_blocks
			    f_bfree
			    f_bavail
			    f_files
			    f_ffree
			    f_fsid
			    f_owner
			    f_type
			    f_flags
			    #+64-bit-target f_fssubtype
			    f_fstypename
			    f_mntonname
			    f_mntfromname) statfs (:struct foreign-statfs))
	(make-filesystem-info
	 :device-name (foreign-string-to-lisp f_mntfromname
					      :max-chars +MAXPATHLEN+)
	 :mount-point (foreign-string-to-lisp f_mntonname
					      :max-chars +MAXPATHLEN+)
	 :type (foreign-string-to-lisp f_fstypename
				       :max-chars +MFSTYPENAMELEN+)
	 :total-bytes (* f_blocks f_bsize)
	 :bytes-free (* f_bfree f_bsize)
	 :bytes-available (* f_bavail f_bsize)))))

;; @@@ 32 bit only?
;(defctype fsblkcnt-t :unsigned-long)
;(defctype fsword-t :int)

#+(and linux 32-bit-target)
(defcstruct foreign-statfs
  (f_type    fsword-t)
  (f_bsize   fsword-t)
  (f_blocks  fsblkcnt-t)
  (f_bfree   fsblkcnt-t)
  (f_bavail  fsblkcnt-t)
  (f_files   fsblkcnt-t)
  (f_ffree   fsblkcnt-t)
  (f_fsid    fsword-t :count 2)
  (f_namelen fsword-t)
  (f_frsize  fsword-t)
  (f_flags   fsword-t)
  (f_spare   fsword-t :count 4))

#+(and linux 64-bit-target)
(defcstruct foreign-statfs
  (f_type    :int64)
  (f_bsize   :int64)
  (f_blocks  :uint64)
  (f_bfree   :uint64)
  (f_bavail  :uint64)
  (f_files   :uint64)
  (f_ffree   :uint64)
  (f_fsid    :int32 :count 2)
  (f_namelen :int64)
  (f_frsize  :int64)
  (f_flags   :int64)
  (f_spare   :int64 :count 4))

#+linux
(defstruct statfs
  "File system statistics."
  type
  bsize
  blocks
  bfree
  bavail
  files
  ffree
  fsid
  namelen
  frsize
  flags
  spare)

;; @@@ Should I really have to do this?
#+linux
(defun convert-statfs (statfs)
  (if (and (pointerp statfs) (null-pointer-p statfs))
      nil
      (with-foreign-slots ((f_type
			    f_bsize
			    f_blocks
			    f_bfree
			    f_bavail
			    f_files
			    f_ffree
			    f_fsid
			    f_namelen
			    f_frsize
			    f_flags
			    f_spare) statfs (:struct foreign-statfs))
	(make-statfs
         :type	  f_type
         :bsize	  f_bsize
         :blocks  f_blocks
         :bfree	  f_bfree
         :bavail  f_bavail
         :files	  f_files
         :ffree	  f_ffree
         :fsid	  (vector (mem-aref f_fsid :int32 0) (mem-aref f_fsid :int32 1))
         :namelen f_namelen
         :frsize  f_frsize
         :flags	  f_flags
         :spare	  f_spare))))

;; (define-foreign-type foreign-statfs-type ()
;;   ()
;;   (:actual-type :pointer)
;;   (:simple-parser foreign-statfs)
;; )

#+freebsd
(eval-when (:compile-toplevel :load-toplevel :execute)
   (define-constant +MFSNAMELEN+ 16)   ; length of fs type name including null
   (define-constant +MNAMELEN+ 88)     ; size of on/from name bufs
   (define-constant +STATFS_VERSION+ #x20030518) ; version of this struct?
   )

#+freebsd
(defcstruct foreign-statfs
  (f_version 	 :uint32)
  (f_type 	 :uint32)
  (f_flags 	 :uint64)
  (f_bsize 	 :uint64)
  (f_iosize 	 :uint64)
  (f_blocks 	 :uint64)
  (f_bfree 	 :uint64)
  (f_bavail 	 :int64)
  (f_files 	 :uint64)
  (f_ffree 	 :int64)
  (f_syncwrites  :uint64)
  (f_asyncwrites :uint64)
  (f_syncreads   :uint64)
  (f_asyncreads  :uint64)
  (f_spare       :uint64 :count 10)
  (f_namemax 	 :uint32)
  (f_owner 	 uid-t)
  (f_fsid 	 :int32 :count 2)
  (f_charspare   :char :count 80)
  (f_fstypename	 :char :count #.+MFSNAMELEN+)
  (f_mntfromname :char :count #.+MNAMELEN+)
  (f_mntonname   :char :count #.+MNAMELEN+))

#+freebsd
(defstruct statfs
  "File system statistics."
  version
  type
  flags
  bsize
  iosize
  blocks
  bfree
  bavail
  files
  ffree
  syncwrites
  asyncwrites
  syncreads
  asyncreads
  namemax
  owner
  fsid
  fstypename
  mntfromname
  mntonname)

;; @@@ It seems I still have to do this.
#+freebsd
(defun convert-statfs (statfs)
  (if (and (pointerp statfs) (null-pointer-p statfs))
      nil
      (with-foreign-slots ((f_version
			    f_type
			    f_flags
			    f_bsize
			    f_iosize
			    f_blocks
			    f_bfree
			    f_bavail
			    f_files
			    f_ffree
			    f_syncwrites
			    f_asyncwrites
			    f_syncreads
			    f_asyncreads
			    f_namemax
			    f_owner
			    f_fsid
			    f_fstypename
			    f_mntfromname
			    f_mntonname
			    ) statfs (:struct foreign-statfs))
	(make-statfs :version     f_version
		     :type        f_type
		     :flags       f_flags
		     :bsize       f_bsize
		     :iosize      f_iosize
		     :blocks      f_blocks
		     :bfree       f_bfree
		     :bavail      f_bavail
		     :files       f_files
		     :ffree       f_ffree
		     :syncwrites  f_syncwrites
		     :asyncwrites f_asyncwrites
		     :syncreads   f_syncreads
		     :asyncreads  f_asyncreads
		     :namemax     f_namemax
		     :owner       f_owner
		     :fsid	  (vector (mem-aref f_fsid :int32 0)
					  (mem-aref f_fsid :int32 1))
		     :fstypename (foreign-string-to-lisp
				  f_fstypename :max-chars +MFSNAMELEN+)
		     :mntfromname (foreign-string-to-lisp
				   f_mntfromname :max-chars +MNAMELEN+)
		     :mntonname (foreign-string-to-lisp
				 f_mntonname :max-chars +MNAMELEN+)
		     ))))

#+freebsd
(defun convert-filesystem-info (statfs)
  (if (and (pointerp statfs) (null-pointer-p statfs))
      nil
      (with-foreign-slots ((f_bsize
			    f_blocks
			    f_bfree
			    f_bavail
			    f_fstypename
			    f_mntonname
			    f_mntfromname) statfs (:struct foreign-statfs))
	(make-filesystem-info
	 :device-name (foreign-string-to-lisp f_mntfromname
					      :max-chars +MNAMELEN+)
	 :mount-point (foreign-string-to-lisp f_mntonname
					      :max-chars +MNAMELEN+)
	 :type (foreign-string-to-lisp f_fstypename
				       :max-chars +MFSNAMELEN+)
	 :total-bytes (* f_blocks f_bsize)
	 :bytes-free (* f_bfree f_bsize)
	 :bytes-available (* f_bavail f_bsize)))))

;;(defmethod translate-from-foreign (statfs (type foreign-statfs-type))
;;  (convert-statfs statfs))

#+(and darwin 64-bit-target)
(defcfun ("statfs$INODE64" real-statfs) :int (path :string)
	 (buf (:pointer (:struct foreign-statfs))))
#+(or (and darwin 32-bit-target) linux freebsd)
(defcfun ("statfs" real-statfs) :int (path :string)
	 (buf (:pointer (:struct foreign-statfs))))
#+(or freebsd linux)
(defcfun ("fstatfs" real-fstatfs) :int (fd :int)
	 (buf (:pointer (:struct foreign-statfs))))
#+(and darwin 64-bit-target)
(defcfun ("fstatfs$INODE64" real-fstatfs) :int (fd :int)
        (buf (:pointer (:struct foreign-statfs))))

(defun statfs (path)
  (with-foreign-object (buf '(:struct foreign-statfs))
    (syscall (real-statfs path buf))
    (convert-statfs buf)))

(defun fstatfs (file-descriptor)
  (with-foreign-object (buf '(:struct foreign-statfs))
    (syscall (real-fstatfs file-descriptor buf))
    (convert-statfs buf)))

;; int getmntinfo(struct statfs **mntbufp, int flags);
#+(and darwin 64-bit-target)
(defcfun ("getmntinfo$INODE64" real-getmntinfo)
    :int (mntbufp :pointer) (flags :int))
#+(or (and darwin 32-bit-target) freebsd)
(defcfun ("getmntinfo" real-getmntinfo)
    :int (mntbufp :pointer) (flags :int))
#+(or darwin freebsd)
(defun getmntinfo (&optional (flags 0))
  (with-foreign-object (ptr :pointer)
    (let ((n (syscall (real-getmntinfo ptr flags))))
      (loop :for i :from 0 :below n
	 :collect (convert-statfs
		   (mem-aptr (mem-ref ptr :pointer)
			     '(:struct foreign-statfs) i))))))

;; Other things on OSX: ?
;;   exchangedata

;; OSX file attributes

(defctype attrgroup-t :uint32)

(defcstruct attrlist
  (bitmapcount :ushort)			; number of attr. bit sets in list
  (reserved    :uint16)			; (to maintain 4-byte alignment)
  (commonattr  attrgroup-t)		; common attribute group
  (volattr     attrgroup-t)		; volume attribute group
  (dirattr     attrgroup-t)		; directory attribute group
  (fileattr    attrgroup-t)		; file attribute group
  (forkattr    attrgroup-t))		; fork attribute group

(defconstant +ATTR_BIT_MAP_COUNT+ 5)

#+darwin
(defcfun getattrlist :int
  (path :string) (attrlist (:pointer (:struct attrlist)))
  (attr-buf (:pointer :void)) (attr-buf-size size-t) (options :unsigned-long))

#+darwin
(defcfun fgetattrlist :int
  (fd :int) (attrList (:pointer (:struct attrlist)))
  (attr-buf (:pointer :void)) (attr-buf-size size-t) (options :unsigned-long))

#+darwin
(defcfun getattrlistat :int
  (fd :int) (path :string) (attrList (:pointer (:struct attrlist)))
  (attr-buf (:pointer :void)) (attr-buf-size size-t) (options :unsigned-long))

#+darwin
(defcfun exchangedata :int
  (path1 :string) (path2 :string) (options :unsigned-int))

;; getfsent [BSD]

(define-constant +fs-types+ '(:hfs :nfs :msdos :cd9660 :fdesc :union))

(defcstruct foreign-fstab-struct
  "File system table."
  (fs_spec	:string)		; block special device name
  (fs_file	:string)		; file system path prefix
  (fs_vfstype	:string)		; File system type, ufs, nfs
  (fs_mntops	:string)		; Mount options ala -o
  (fs_type	:string)		; FSTAB_* from fs_mntops
  (fs_freq	:int)			; dump frequency, in days
  (fs_passno	:int))			; pass number on parallel fsck

(defstruct fstab
  "File system table."
  spec
  file
  vfstype
  mntops
  type
  freq
  passno)

(define-foreign-type foreign-fstab-type ()
  ()
  (:actual-type :pointer)
  (:simple-parser foreign-fstab))

(defmethod translate-from-foreign (fstab (type foreign-fstab-type))
  (if (and (pointerp fstab) (null-pointer-p fstab))
      nil
      (with-foreign-slots ((fs_spec
			    fs_file
			    fs_vfstype
			    fs_mntops
			    fs_type
			    fs_freq
			    fs_passno) fstab (:struct foreign-fstab-struct))
	(make-fstab
	 :spec		fs_spec
	 :file		fs_file
	 :vfstype	fs_vfstype
	 :mntops	fs_mntops
	 :type		fs_type
	 :freq		fs_freq
	 :passno	fs_passno))))

(defcfun getfsent  foreign-fstab)
(defcfun getfsspec foreign-fstab (spec :string))
(defcfun getfsfile foreign-fstab (file :string))
(defcfun setfsent :int)
(defcfun endfsent :void)

;; getmntent - Linux

(defstruct mount-entry
  "File system description."
  fsname   ; name of mounted file system
  dir	   ; file system path prefix
  type	   ; mount type
  opts	   ; mount options
  freq	   ; dump frequency in days
  passno)  ; pass number on parallel fsck

;; (defmacro with-mount-entry-file ((var name) &body body)
;;   `(with-open-file (,var ,name)
;;      ,@body))

;; Because the C API is so bogus and requires stdio, just do it ourselves.
(defun get-mount-entry (stream)
  (let (line words)
    ;; Skip blank and comment lines
    (loop :do (setf line (read-line stream nil nil))
       :while (and line
		   (or (zerop (length line))
		       (char= (char line 0) #\#))))
    (when line
      (setf words
	    (split-sequence nil line
			    :test (λ (a b)
				     (declare (ignore a))
				     (or (char= b #\space) (char= b #\tab)))))
      (make-mount-entry
       :fsname (first words)
       :dir    (second words)
       :type   (third words)
       :opts   (fourth words)
       :freq   (fifth words)
       :passno (sixth words)))))

#+linux (defparameter *mtab-file* "/etc/mtab")

(defun mounted-filesystems ()
  "Return a list of filesystem info."
  #+(or darwin freebsd)
  (with-foreign-object (ptr :pointer)
    (let ((n (syscall (real-getmntinfo ptr 0))))
      (loop :for i :from 0 :below n
	 :collect (convert-filesystem-info
		   (mem-aptr (mem-ref ptr :pointer)
			     '(:struct foreign-statfs) i)))))
  #+linux
  (with-open-file (stream *mtab-file* :direction :input)
    (loop :with entry
       :while (setf entry (get-mount-entry stream))
       :collect
       (progn
	 (multiple-value-bind (fs err)
	     (ignore-errors (statfs (mount-entry-dir entry)))
	   (if err
	       (if (eql (opsys-error-code err) +EACCES+)
		   ;; If we can't access the mount point, just ignore it.
		   (make-filesystem-info
		    :device-name     (mount-entry-fsname entry)
		    :mount-point     (mount-entry-dir entry)
		    :type	     (mount-entry-type entry))
		   (signal err))
	       (make-filesystem-info
		:device-name     (mount-entry-fsname entry)
		:mount-point     (mount-entry-dir entry)
		:type	         (mount-entry-type entry)
		:total-bytes     (* (statfs-bsize fs) (statfs-blocks fs))
		:bytes-free	 (* (statfs-bsize fs) (statfs-bfree fs))
		:bytes-available (* (statfs-bsize fs) (statfs-bavail fs)))))))))

(defun mount-point-of-file (file)
  "Try to find the mount of FILE. This might not always be right."
  #+linux
  ;; I suppose this could work on other systems too, but it's certainly
  ;; more efficient and effective to get it from the statfs.
  (let (longest len (max-len 0) (real-name (safe-namestring (truename file))))
    (loop :for f :in
       (remove-if
	(_ (not (begins-with (car _) real-name)))
	(mapcar (_ (cons (filesystem-info-mount-point _)
			 (filesystem-info-device-name _)))
		(mounted-filesystems)))
       :do
       (when (> (setf len (length (car f))) max-len)
	 (setf longest f max-len len)))
    longest)
  #+(or darwin freebsd)
  (handler-case
      (let ((s (statfs file)))
	(cons (statfs-mntonname s) (statfs-mntfromname s)))
    (os-unix:posix-error (c)
      (if (find (opsys-error-code c)
		`(,os-unix:+EPERM+ ,os-unix:+ENOENT+ ,os-unix:+EACCES+))
	  nil
	  (list (opsys-error-code c) c)))))

;; mount/unmount??

;; quotactl??

;; fsstat?

;; End