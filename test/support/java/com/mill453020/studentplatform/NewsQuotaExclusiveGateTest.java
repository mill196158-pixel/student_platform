package com.mill453020.studentplatform;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

public final class NewsQuotaExclusiveGateTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0) {
            if ("quarantine".equals(args[0])) {
                Path path = Path.of(args[1]);
                try {
                    NewsQuotaExclusiveGate.runSync(path, () -> {
                        throw new NewsQuotaExclusiveGate.UnsettledResourceException(new Object(), new IOException("synthetic close failure"));
                    });
                    throw new AssertionError("uncertain close accepted");
                } catch (NewsQuotaExclusiveGate.UnsettledResourceException expected) { /* quarantine */ }
                check(!NewsQuotaExclusiveGate.runSync(path, () -> { throw new AssertionError("entered quarantine"); }), "quarantine same-process");
                child(path, "busy");
                return;
            }
            boolean result = NewsQuotaExclusiveGate.runSync(Path.of(args[1]), () -> {});
            check(args[0].equals(result ? "entered" : "busy"), "child lock result");
            return;
        }
        Path root = Files.createTempDirectory("news-gate-test-");
        Path lock = root.resolve("lease.lock");
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            check(!NewsQuotaExclusiveGate.runSync(lock, () -> { throw new AssertionError("entered"); }), "missing denies");
            check(!Files.exists(lock), "missing lock created");
            Files.createFile(lock);
            CountDownLatch entered = new CountDownLatch(1);
            CountDownLatch finish = new CountDownLatch(1);
            Future<Boolean> work = executor.submit(() -> NewsQuotaExclusiveGate.runSync(lock, () -> {
                entered.countDown();
                finish.await();
            }));
            check(entered.await(3, TimeUnit.SECONDS), "first operation did not start");
            try { work.get(30, TimeUnit.MILLISECONDS); throw new AssertionError("missing timeout"); }
            catch (TimeoutException expected) { /* observer timeout does not cancel raw I/O */ }
            check(!NewsQuotaExclusiveGate.runSync(lock, () -> { throw new AssertionError("entered"); }), "same-process overlap");
            child(lock, "busy");
            finish.countDown();
            check(work.get(3, TimeUnit.SECONDS), "settled result");
            child(lock, "entered");
            try {
                NewsQuotaExclusiveGate.runSync(lock, () -> { throw new IOException("action failure"); });
                throw new AssertionError("callback exception swallowed");
            } catch (IOException expected) { check("action failure".equals(expected.getMessage()), "wrong error"); }
            check(NewsQuotaExclusiveGate.runSync(lock, () -> {}), "exception retained lock");
            check(NewsQuotaExclusiveGate.runSync(lock, () ->
                check(!NewsQuotaExclusiveGate.runSync(lock, () -> {
                    throw new AssertionError("reentrant callback entered");
                }), "reentrant operation not denied")), "outer operation rejected");
            child(lock, "quarantine");
            check(NewsQuotaExclusiveGate.runSync(lock, () -> {}), "child quarantine survived process exit");
            System.out.println("NEWS_GATE_SYNTHETIC_PASS");
        } finally {
            executor.shutdownNow();
            Files.deleteIfExists(lock);
            Files.deleteIfExists(root);
        }
    }

    private static void child(Path lock, String expected) throws Exception {
        String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
        Process child = new ProcessBuilder(java, "-cp", System.getProperty("java.class.path"),
                NewsQuotaExclusiveGateTest.class.getName(), expected, lock.toString())
                .inheritIO().start();
        check(child.waitFor(5, TimeUnit.SECONDS), "child timed out");
        check(child.exitValue() == 0, "child failed");
    }
}
