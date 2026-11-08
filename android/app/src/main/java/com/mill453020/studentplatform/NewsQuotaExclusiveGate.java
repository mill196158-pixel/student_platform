package com.mill453020.studentplatform;

import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.HashSet;
import java.util.Set;
import java.util.Map;
import java.util.HashMap;

/** Cooperating-writer gate, not wired into the app. Android API 26+ only.
 * Participants must never delete or replace the enrolled lock file. Static
 * claims cover one classloader; cross-engine Android behavior needs validation.
 */
final class NewsQuotaExclusiveGate {
    private static final Set<Path> IN_PROCESS = new HashSet<>();
    private static final Map<Path, Object[]> QUARANTINE = new HashMap<>();
    private NewsQuotaExclusiveGate() {}

    interface SynchronousOperation { void run() throws Exception; }
    static final class UnsettledResourceException extends Exception {
        final Object resource;
        UnsettledResourceException(Object resource, Throwable cause) { super(cause); this.resource = resource; }
    }

    /** Run only on a worker. Operation must not return before its real I/O has
     * settled. Observer timeouts must not interrupt/cancel this operation. */
    static boolean runSync(Path lockPath, SynchronousOperation operation) throws Exception {
        if (lockPath == null || operation == null ||
                !Files.isRegularFile(lockPath, LinkOption.NOFOLLOW_LINKS)) return false;
        final Path canonical;
        try { canonical = lockPath.toRealPath(); }
        catch (IOException unavailable) { return false; }
        synchronized (IN_PROCESS) {
            if (!IN_PROCESS.add(canonical)) return false;
        }
        FileChannel channel = null;
        FileLock lock = null;
        boolean closed = true;
        boolean quarantined = false;
        try {
            try { channel = FileChannel.open(canonical, StandardOpenOption.READ, StandardOpenOption.WRITE); }
            catch (IOException unavailable) { return false; }
            try { lock = channel.tryLock(); }
            catch (IOException | OverlappingFileLockException unavailable) { return false; }
            if (lock == null) return false;
            operation.run();
            return true;
        } catch (UnsettledResourceException uncertain) {
            synchronized (IN_PROCESS) {
                QUARANTINE.put(canonical, new Object[] {channel, lock, uncertain.resource});
            }
            quarantined = true;
            throw uncertain;
        } finally {
            if (!quarantined) {
            try { if (lock != null) lock.release(); } catch (IOException failure) { closed = false; }
            try { if (channel != null) channel.close(); } catch (IOException failure) { closed = false; }
            if (closed) synchronized (IN_PROCESS) { IN_PROCESS.remove(canonical); }
            else synchronized (IN_PROCESS) { QUARANTINE.put(canonical, new Object[] {channel, lock}); }
            // If close/release failed the claim remains quarantined until process exit.
            if (!closed) throw new IOException("News quota gate did not close safely");
            }
        }
    }
}
