package dev.andriloft.lifecycle;

import android.app.Application;
import android.util.Log;

public class LifecycleApplication extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        Log.i("Lifecycle", "application");
    }
}
