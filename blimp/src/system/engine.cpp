//
// Created by lucien on 2/13/20.
//
#include "core/core.h"
#include "engine.h"
#include "log.h"
#include <SDL.h>
#include <GL/glew.h>
#include <uuid/uuid.h>
#include "core/slotmap/slotmap.h"


const int WINDOW_WIDTH = 800;
const int WINDOW_HEIGHT = 600;
RandomMersenne* ra;
GLuint VAO, VBO, program, uniformXMove;

bool direction = true;
float triOffset = 0.0f;
float triMaxOffset = 0.7f;
float triIncrement = 0.005f;

//Vertex Shader
static const char* vertex_shader_code = "               \n\
#version 330                                            \n\
layout (location = 0) in vec3 pos;                      \n\
uniform float xMove;                                    \n\
void main()                                             \n\
{                                                       \n\
    gl_Position = vec4(pos, 1.0) + vec4(xMove, 0, 0, 0);\n\
}                                                       \n\
";

static const char* fragment_shader_code = "             \n\
#version 330                                            \n\
out vec4 color;                                         \n\
void main()                                             \n\
{                                                       \n\
    color = vec4(1.0f, 0.0f, 0.0f, 1.0f);               \n\
}                                                       \n\
";

namespace blimp
{

    bool Engine::init()
    {
        if(SDL_Init(SDL_INIT_VIDEO) < 0)
        {
            BLIMP_ERROR("Failed to init SDL!\n");
            return false;
        }

        window = SDL_CreateWindow(window_name.c_str(), SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                WINDOW_WIDTH, WINDOW_HEIGHT, SDL_WINDOW_OPENGL);

        if(!window)
        {
            BLIMP_ERROR("Unable to create window!\n");
            check_SDL_error();
            return false;
        }

        context = SDL_GL_CreateContext(window);


        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);

        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);

        SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

        glewExperimental = GL_TRUE;

        if(glewInit() != GLEW_OK)
        {
            BLIMP_ERROR("GLEW initialization failed!");
            return false;
        }

        SDL_GL_GetDrawableSize(window, &drawableX, &drawableY);

        glViewport(0, 0, drawableX, drawableY);


        // Create Triangle
        std::array<GLfloat, 9> vertices = {
            -1.0f, -1.0f, 0.0f,
            1.0f, -1.0f, 0.0f,
            0.0f, 1.0f, 0.0f
        };

        glGenVertexArrays(1, &VAO);
        glBindVertexArray(VAO);

        glGenBuffers(1, &VBO);
        glBindBuffer(GL_ARRAY_BUFFER, VBO);
        glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices.data(), GL_STATIC_DRAW);

        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, 0);
        glEnableVertexAttribArray(0);

        glBindBuffer(GL_ARRAY_BUFFER, 0);

        glBindVertexArray(0);

        // Compile shaders
        program = glCreateProgram();
        if(!program)
        {
            BLIMP_ERROR("Error creating shader program!\n");
            return false;
        }

        // Vertex shader
        GLuint vertex_shader = glCreateShader(GL_VERTEX_SHADER);
        GLint vertex_shader_length = strlen(vertex_shader_code);
        glShaderSource(vertex_shader, 1, &vertex_shader_code, &vertex_shader_length);
        glCompileShader(vertex_shader);

        GLint result = 0;
        glGetShaderiv(vertex_shader, GL_COMPILE_STATUS, &result);
        if(!result)
        {
            GLchar log[1024] = {};
            glGetShaderInfoLog(vertex_shader, sizeof(log), nullptr, log);
            BLIMP_ERROR("Error compiling the {} shader: {}", "vertex", log);
        }
        glAttachShader(program, vertex_shader);

        // Fragment shader
        GLuint fragment_shader = glCreateShader(GL_FRAGMENT_SHADER);
        GLint fragment_shader_length = strlen(fragment_shader_code);
        glShaderSource(fragment_shader, 1, &fragment_shader_code, &fragment_shader_length);
        glCompileShader(fragment_shader);

        glGetShaderiv(fragment_shader, GL_COMPILE_STATUS, &result);
        if(!result)
        {
            GLchar log[1024] = {};
            glGetShaderInfoLog(fragment_shader, sizeof(log), nullptr, log);
            BLIMP_ERROR("Error compiling the {} shader: {}", "fragment", log);
        }
        glAttachShader(program, fragment_shader);

        glLinkProgram(program);
        glGetProgramiv(program, GL_LINK_STATUS, &result);
        if(!result)
        {
            GLchar log[1024] = {};
            glGetProgramInfoLog(program, sizeof(log), nullptr, log);
            BLIMP_ERROR("Error compiling program: ", log);
        }

        uniformXMove = glGetUniformLocation(program, "xMove");

        return true;
    }

    void Engine::set_window_name(const std::string& name)
    {
        window_name = name;
    }

    void Engine::run() {

        bool loop = true;
        while(loop)
        {
            SDL_Event event;
            while(SDL_PollEvent(&event))
            {
                if(event.type == SDL_QUIT)
                {
                    loop = false;
                }
                if(event.type == SDL_KEYDOWN)
                {
                    switch (event.key.keysym.sym)
                    {
                        case SDLK_ESCAPE:
                            loop = false;
                            break;
                        default:
                            break;
                    }
                }
            }

            glClearColor(0.0, 0.0, 0.0, 1.0);
            glClear(GL_COLOR_BUFFER_BIT);

            glUseProgram(program);

            if(direction)
            {
                triOffset += triIncrement;
            } else {
                triOffset -= triIncrement;
            }

            if(abs(triOffset) >= abs(triMaxOffset)) {
                direction = !direction;
            }
            glUniform1f(uniformXMove, triOffset);

            glBindVertexArray(VAO);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glBindVertexArray(0);

            glUseProgram(0);

            SDL_GL_SwapWindow(window);

        }
    }

    void Engine::shutdown()
    {
        SDL_GL_DeleteContext(context);
        SDL_DestroyWindow(window);
        SDL_Quit();
    }

    void Engine::check_SDL_error()
    {
        std::string error = SDL_GetError();
        if(!error.empty())
        {
            BLIMP_ERROR("SDL Error: {}", error);
            SDL_ClearError();
        }
    }


}