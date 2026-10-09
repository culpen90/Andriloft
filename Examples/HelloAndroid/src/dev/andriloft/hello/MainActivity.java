package dev.andriloft.hello;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

/** A regular Android Activity, compiled to DEX without host-specific code. */
public class MainActivity extends Activity {
    public int taps;
    public TextView counterText;
    public EditText nameInput;
    public SharedPreferences preferences;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        preferences = getSharedPreferences("counter", 0);
        taps = preferences.getInt("count", 0);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(28, 24, 28, 24);
        root.setBackgroundColor(0xfff6f7fb);

        TextView heading = new TextView(this);
        heading.setText("Hello from Android");
        heading.setTextSize(28);
        heading.setTextColor(0xff202a44);
        root.addView(heading, new LinearLayout.LayoutParams(-1, -2));

        TextView description = new TextView(this);
        description.setText("This APK runs its Android bytecode through Andriloft and uses native Mac controls.");
        description.setTextSize(15);
        description.setPadding(0, 12, 0, 24);
        description.setTextColor(0xff546078);
        root.addView(description, new LinearLayout.LayoutParams(-1, -2));

        counterText = new TextView(this);
        counterText.setText(new StringBuilder().append("Button taps: ").append(taps).toString());
        counterText.setTextSize(20);
        counterText.setPadding(0, 8, 0, 10);
        root.addView(counterText, new LinearLayout.LayoutParams(-1, -2));

        Button countButton = new Button(this);
        countButton.setText("Count a tap");
        countButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                taps = taps + 1;
                preferences.edit().putInt("count", taps).apply();
                counterText.setText(new StringBuilder()
                    .append("Button taps: ")
                    .append(taps)
                    .toString());
            }
        });
        root.addView(countButton, new LinearLayout.LayoutParams(-1, -2));

        TextView nameLabel = new TextView(this);
        nameLabel.setText("Your name");
        nameLabel.setTextSize(15);
        nameLabel.setPadding(0, 22, 0, 8);
        root.addView(nameLabel, new LinearLayout.LayoutParams(-1, -2));

        nameInput = new EditText(this);
        nameInput.setHint("Type a name");
        nameInput.setText("Mac user");
        nameInput.setTextSize(16);
        root.addView(nameInput, new LinearLayout.LayoutParams(-1, -2));

        Button greetButton = new Button(this);
        greetButton.setText("Say hello");
        greetButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                String greeting = new StringBuilder()
                    .append("Hello, ")
                    .append(nameInput.getText().toString())
                    .append("!")
                    .toString();
                Toast.makeText(MainActivity.this, greeting, Toast.LENGTH_SHORT).show();
            }
        });
        root.addView(greetButton, new LinearLayout.LayoutParams(-1, -2));

        setContentView(root);
    }
}
